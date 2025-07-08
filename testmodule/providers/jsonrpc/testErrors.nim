import std/importutils
import std/sequtils
import std/typetraits
import std/net

import pkg/stew/byteutils
import pkg/asynctest/chronos/unittest
import pkg/chronos/apps/http/httpclient
import pkg/serde
import pkg/questionable
import pkg/ethers/providers/jsonrpc except toJson, `%`, `%*`
import pkg/ethers/providers/jsonrpc/errors except toJson, `%`, `%*`
import pkg/ethers/erc20 except toJson, `%`, `%*`
import pkg/json_rpc/clients/httpclient except toJson, `%`, `%*`
import pkg/json_rpc/clients/websocketclient except toJson, `%`, `%*`
import pkg/websock/websock
import pkg/websock/http/common
import ./mocks/mockHttpServer
import ./mocks/mockWebSocketServer
import ../../examples
import ../../hardhat

suite "JSON RPC errors":
  test "converts JSON RPC error to Nim error":
    let error = %*{"message": "some error"}
    check JsonRpcProviderError.new(error).msg == "some error"

  test "converts error data to bytes":
    let error =
      %*{"message": "VM Exception: reverted with 'some error'", "data": "0xabcd"}
    check JsonRpcProviderError.new(error).data == some @[0xab'u8, 0xcd'u8]

  test "converts nested error data to bytes":
    let error =
      %*{
        "message": "VM Exception: reverted with 'some error'",
        "data":
          {"message": "VM Exception: reverted with 'some error'", "data": "0xabcd"},
      }
    check JsonRpcProviderError.new(error).data == some @[0xab'u8, 0xcd'u8]

type
  TestToken = ref object of Erc20Token
  Before = proc(): Future[void] {.gcsafe, raises: [].}
    # A proc that runs before each test

proc runBefore(before: Before) {.async.} =
  if before != nil:
    await before()

method mint(
  token: TestToken, holder: Address, amount: UInt256
): Confirmable {.base, contract.}

suite "Network errors - HTTP":
  var provider: JsonRpcProvider
  var mockServer: MockHttpServer
  var token: TestToken
  var blockingSocket: Socket

  setup:
    mockServer = MockHttpServer.init(initTAddress("127.0.0.1:0"))
    mockServer.start()
    provider = JsonRpcProvider.new("http://" & $mockServer.address)

    let deployment = readDeployment()
    token = TestToken.new(!deployment.address(TestToken), provider)

  teardown:
    await provider.close()
    await mockServer.stop()
    if not blockingSocket.isNil:
      blockingSocket.close()
      blockingSocket = nil

  proc registerRpcMethods(response: RpcResponse) =
    mockServer.registerRpcResponse("eth_accounts", response)
    mockServer.registerRpcResponse("eth_call", response)
    mockServer.registerRpcResponse("eth_sendTransaction", response)
    mockServer.registerRpcResponse("eth_sendRawTransaction", response)
    mockServer.registerRpcResponse("eth_newBlockFilter", response)
    mockServer.registerRpcResponse("eth_newFilter", response)

  proc testCustomResponse(
      testNamePrefix: string,
      response: RpcResponse,
      errorType: type CatchableError,
      before: Before = nil,
  ) =
    let prefix = testNamePrefix & " when "

    test prefix & "sending a manual RPC method request":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        discard await provider.send("eth_accounts")

    test prefix &
      "calling a provider method that converts errors when calling a generated RPC request":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        discard await provider.listAccounts()

    test prefix & "calling a view method of a contract":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        token = TestToken.new(token.address, provider.getSigner())
        discard await token.balanceOf(Address.example)

    test prefix & "calling a contract method that executes a transaction":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        token = TestToken.new(token.address, provider.getSigner())
        discard await token.mint(
          Address.example,
          100.u256,
          TransactionOverrides(gasLimit: 100.u256.some, chainId: 1.u256.some),
        )

    test prefix & "sending a manual transaction":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        let tx = Transaction.example
        discard await provider.getSigner().sendTransaction(tx)

    test prefix & "sending a raw transaction":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        const pk_with_funds =
          "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
        let wallet = !Wallet.new(pk_with_funds)
        let tx = Transaction(
          to: wallet.address,
          nonce: some 0.u256,
          chainId: some 31337.u256,
          gasPrice: some 1_000_000_000.u256,
          gasLimit: some 21_000.u256,
        )
        let signedTx = await wallet.signTransaction(tx)
        discard await provider.sendTransaction(signedTx)

    test prefix & "subscribing to blocks":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        let emptyHandler = proc(blckResult: ?!Block) =
          discard
        discard await provider.subscribe(emptyHandler)

    test prefix & "subscribing to logs":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        let filter =
          EventFilter(address: Address.example, topics: @[array[32, byte].example])
        let emptyHandler = proc(log: ?!Log) =
          discard
        discard await provider.subscribe(filter, emptyHandler)

  proc testCustomHttpResponse(
      errorName: string,
      responseHttpCode: HttpCode,
      responseText: string,
      errorType: type CatchableError,
  ) =
    let response = proc(
        request: HttpRequestRef
    ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
      try:
        return await request.respond(responseHttpCode, responseText)
      except HttpWriteError as exc:
        return defaultResponse(exc)

    let prefix = errorName & " error response is converted to " & errorType.name

    testCustomResponse(prefix, response, errorType)

  testCustomHttpResponse("429", Http429, "Too many requests", HttpRequestLimitError)
  testCustomHttpResponse("408", Http408, "Request timed out", HttpRequestTimeoutError)
  testCustomHttpResponse("non-429", Http500, "Server error", JsonRpcProviderError)
  testCustomResponse(
    "raises RpcNetworkError after a timeout waiting for reading response headers",
    response = proc(
        request: HttpRequestRef
    ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
      try:
        await sleepAsync(5.minutes)
        return await request.respond(Http200, "OK")
      except HttpWriteError as exc:
        return defaultResponse(exc),
    RpcNetworkError,
    before = proc(): Future[void] {.async.} =
      privateAccess(JsonRpcProvider)
      privateAccess(RpcHttpClient)
      let rpcClient = await provider.client
      let client: RpcHttpClient = (RpcHttpClient)(rpcClient)
      client.httpSession = HttpSessionRef.new(headersTimeout = 1.millis),
  )

  testCustomResponse(
    "raises RpcNetworkError for a closed connection",
    response = proc(
        request: HttpRequestRef
    ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
      # Simulate a closed connection
      return HttpResponseRef.new(),
    RpcNetworkError,
    before = proc(): Future[void] {.async.} =
      await mockServer.stop()
    ,
  )

  testCustomResponse(
    "raises RpcNetworkError for a timed out connection",
    response = proc(
        request: HttpRequestRef
    ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
      # Simulate a closed connection
      return HttpResponseRef.new(),
    RpcNetworkError,
      # msg: Failed to send POST Request with JSON-RPC: Connection timed out
    before = proc(): Future[void] {.async.} =
      privateAccess(JsonRpcProvider)
      privateAccess(RpcHttpClient)
      let rpcClient = await provider.client
      let client: RpcHttpClient = (RpcHttpClient)(rpcClient)
      client.httpSession.connectTimeout = 10.millis

      blockingSocket = newSocket()
      blockingSocket.setSockOpt(OptReuseAddr, true)
      blockingSocket.bindAddr(Port(9999))

      await client.connect("http://localhost:9999")
    ,
  )

suite "Network errors - WebSocket":
  var provider: JsonRpcProvider
  var token: TestToken
  var mockWsServer: MockWebSocketServer

  setup:
    mockWsServer = MockWebSocketServer.init(initTAddress("127.0.0.1:0"))
    await mockWsServer.start()
    # Get the actual bound address
    provider = JsonRpcProvider.new("ws://" & $mockWsServer.localAddress)

    let deployment = readDeployment()
    token = TestToken.new(!deployment.address(TestToken), provider)

  teardown:
    await mockWsServer.stop()
    try:
      await provider.close()
    except WebsocketConnectionError:
      # WebsocketConnectionError is raised when the connection is already closed
      discard
    provider = nil

  proc registerRpcMethods(response: WebSocketResponse) =
    mockWsServer.registerRpcResponse("eth_accounts", response)
    mockWsServer.registerRpcResponse("eth_call", response)
    mockWsServer.registerRpcResponse("eth_sendTransaction", response)
    mockWsServer.registerRpcResponse("eth_sendRawTransaction", response)
    mockWsServer.registerRpcResponse("eth_subscribe", response)

  proc testCustomResponse(
      name: string,
      errorType: type CatchableError,
      response: WebSocketResponse,
      before: Before = nil,
  ) =
    test name & " when sending a manual RPC method request":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        discard await provider.send("eth_accounts")

    test name &
      " when calling a provider method that converts errors when calling a generated RPC request":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        discard await provider.listAccounts()

    test name & " when calling a view method of a contract":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        token = TestToken.new(token.address, provider.getSigner())
        discard await token.balanceOf(Address.example)

    test name & " when calling a contract method that executes a transaction":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        token = TestToken.new(token.address, provider.getSigner())
        discard await token.mint(
          Address.example,
          100.u256,
          TransactionOverrides(gasLimit: 100.u256.some, chainId: 1.u256.some),
        )

    test name & " when sending a manual transaction":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        let tx = Transaction.example
        discard await provider.getSigner().sendTransaction(tx)

    test name & " when sending a raw transaction":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        const pk_with_funds =
          "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
        let wallet = !Wallet.new(pk_with_funds)
        let tx = Transaction(
          to: wallet.address,
          nonce: some 0.u256,
          chainId: some 31337.u256,
          gasPrice: some 1_000_000_000.u256,
          gasLimit: some 21_000.u256,
        )
        let signedTx = await wallet.signTransaction(tx)
        discard await provider.sendTransaction(signedTx)

    test name & " when subscribing to blocks":
      privateAccess(JsonRpcProvider)
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        let emptyHandler = proc(blckResult: ?!Block) =
          discard
        discard await provider.subscribe(emptyHandler)

    test name & " when subscribing to logs":
      registerRpcMethods(response)
      await runBefore(before)
      expect errorType:
        let filter =
          EventFilter(address: Address.example, topics: @[array[32, byte].example])
        let emptyHandler = proc(log: ?!Log) =
          discard
        discard await provider.subscribe(filter, emptyHandler)

  test "should not raise error on normal connection and request":
    mockWsServer.registerRpcResponse(
      "eth_accounts",
      proc(ws: WSSession) {.async.} =
        let response =
          ResponseTx(jsonrpc: "2.0", id: 1, result: % @["123"], kind: rkResult)
        await ws.send(response.toJson)
      ,
    )

    let accounts = await provider.send("eth_accounts")
    check @["123"] == !seq[string].fromJson(accounts)

  testCustomResponse(
    "should raise JsonRpcProviderError for a returned error response",
    JsonRpcProviderError,
    proc(ws: WSSession) {.async.} =
      let response = ResponseTx(
        jsonrpc: "2.0",
        id: 1,
        error: ResponseError(code: 1, message: "some error"),
        kind: rkError,
      )
      await ws.send(response.toJson)
    ,
  )
  testCustomResponse(
    "raises WebsocketConnectionError for closed connection",
    WebsocketConnectionError,
    proc(ws: WSSession) {.async.} =
      # Simulate a closed connection
      await ws.close(StatusGoingAway, "Going away")
    ,
  )
  testCustomResponse(
    "raises WebsocketConnectionError for failed connection",
    WebsocketConnectionError,
    response = proc(ws: WSSession) {.async.} =
      return ,
    before = proc() {.async.} =
      # Used to simulate an HttpError, which is also raised for "Timeout expired
      # while receiving headers", however replicating that exact scenario would
      # take 120s as the HttpHeadersTimeout is hardcoded to 120 seconds.
      provider = JsonRpcProvider.new("ws://localhost:9999"),
  )
  testCustomResponse(
    "raises JsonRpcProviderError for exceptions in onProcessMessage callback",
    JsonRpcProviderError,
    response = proc(ws: WSSession) {.async.} =
      let response = ResponseTx(jsonrpc: "2.0", id: 1, result: %"", kind: rkResult)
      await ws.send(response.toJson)
    ,
    before = proc() {.async.} =
      privateAccess(JsonRpcProvider)
      let rpcClient = await provider.client
      rpcClient.onProcessMessage = proc(
          client: RpcClient, line: string
      ): Result[bool, string] {.gcsafe, raises: [].} =
        return err "Some error",
  )
