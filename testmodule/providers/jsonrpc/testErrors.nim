import std/importutils
import std/sequtils
import std/typetraits
import std/net

import stew/byteutils
import pkg/asynctest/chronos/unittest
import pkg/chronos/apps/http/httpclient
import pkg/serde
import pkg/questionable
import pkg/ethers/providers/jsonrpc
import pkg/ethers/providers/jsonrpc/errors
import pkg/ethers/erc20
import pkg/json_rpc/clients/httpclient
import ./mocks/mockHttpServer
import ../../examples
import ../../hardhat

suite "JSON RPC errors":

  test "converts JSON RPC error to Nim error":
    let error = %*{ "message": "some error" }
    check JsonRpcProviderError.new(error).msg == "some error"

  test "converts error data to bytes":
    let error = %*{
      "message": "VM Exception: reverted with 'some error'",
      "data": "0xabcd"
    }
    check JsonRpcProviderError.new(error).data == some @[0xab'u8, 0xcd'u8]

  test "converts nested error data to bytes":
    let error = %*{
      "message": "VM Exception: reverted with 'some error'",
      "data": {
        "message": "VM Exception: reverted with 'some error'",
        "data": "0xabcd"
      }
    }
    check JsonRpcProviderError.new(error).data == some @[0xab'u8, 0xcd'u8]

type
  TestToken = ref object of Erc20Token

method mint(token: TestToken, holder: Address, amount: UInt256): Confirmable {.base, contract.}

suite "Network errors - HTTP":

  var provider: JsonRpcProvider
  var mockServer: MockHttpServer
  var token: TestToken

  setup:
    mockServer = MockHttpServer.init(initTAddress("127.0.0.1:0"))
    mockServer.start()
    provider = JsonRpcProvider.new("http://" & $mockServer.address)

    let deployment = readDeployment()
    token = TestToken.new(!deployment.address(TestToken), provider)

  teardown:
    await provider.close()
    await mockServer.stop()

  proc registerRpcMethods(response: RpcResponse) =
    mockServer.registerRpcResponse("eth_accounts", response)
    mockServer.registerRpcResponse("eth_call", response)
    mockServer.registerRpcResponse("eth_sendTransaction", response)
    mockServer.registerRpcResponse("eth_sendRawTransaction", response)
    mockServer.registerRpcResponse("eth_newBlockFilter", response)
    mockServer.registerRpcResponse("eth_newFilter", response)
    # mockServer.registerRpcResponse("eth_subscribe", response) # TODO: handle
    # eth_subscribe for websockets

  proc testCustomResponse(errorName: string, responseHttpCode: HttpCode, responseText: string, errorType: type CatchableError) =
    let response = proc(request: HttpRequestRef): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
      try:
        return await request.respond(responseHttpCode, responseText)
      except HttpWriteError as exc:
        return defaultResponse(exc)

    let testNamePrefix = errorName & " error response is converted to " & errorType.name & " for "
    test testNamePrefix & "sending a manual RPC method request":
      registerRpcMethods(response)
      expect errorType:
        discard await provider.send("eth_accounts")

    test testNamePrefix & "calling a provider method that converts errors when calling a generated RPC request":
      registerRpcMethods(response)
      expect errorType:
        discard await provider.listAccounts()

    test testNamePrefix & "calling a view method of a contract":
      registerRpcMethods(response)
      expect errorType:
        discard await token.balanceOf(Address.example)

    test testNamePrefix & "calling a contract method that executes a transaction":
      registerRpcMethods(response)
      expect errorType:
        token = TestToken.new(token.address, provider.getSigner())
        discard await token.mint(
          Address.example, 100.u256,
          TransactionOverrides(gasLimit: 100.u256.some, chainId: 1.u256.some)
        )

    test testNamePrefix & "sending a manual transaction":
      registerRpcMethods(response)
      expect errorType:
        let tx = Transaction.example
        discard await provider.getSigner().sendTransaction(tx)

    test testNamePrefix & "sending a raw transaction":
      registerRpcMethods(response)
      expect errorType:
        const pk_with_funds = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
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

    test testNamePrefix & "subscribing to blocks":
      registerRpcMethods(response)
      expect errorType:
        let emptyHandler = proc(blckResult: ?!Block) = discard
        discard await provider.subscribe(emptyHandler)

    test testNamePrefix & "subscribing to logs":
      registerRpcMethods(response)
      expect errorType:
        let filter = EventFilter(address: Address.example, topics: @[array[32, byte].example])
        let emptyHandler = proc(log: ?!Log) = discard
        discard await provider.subscribe(filter, emptyHandler)

  testCustomResponse("429", Http429, "Too many requests", HttpRequestLimitError)
  testCustomResponse("408", Http408, "Request timed out", HttpRequestTimeoutError)
  testCustomResponse("non-429", Http500, "Server error", JsonRpcProviderError)

  test "raises RpcNetworkError when reading response headers times out":
    privateAccess(JsonRpcProvider)
    privateAccess(RpcHttpClient)

    let responseTimeout = proc(request: HttpRequestRef): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
      try:
        await sleepAsync(5.minutes)
        return await request.respond(Http200, "OK")
      except HttpWriteError as exc:
        return defaultResponse(exc)

    let rpcClient = await provider.client
    let client: RpcHttpClient = (RpcHttpClient)(rpcClient)
    client.httpSession = HttpSessionRef.new(headersTimeout = 1.millis)
    mockServer.registerRpcResponse("eth_accounts", responseTimeout)

    expect RpcNetworkError:
      discard await provider.send("eth_accounts")

  test "raises RpcNetworkError when connection is closed":
    await mockServer.stop()
    expect RpcNetworkError:
      discard await provider.send("eth_accounts")

  test "raises RpcNetworkError when connection times out":
    privateAccess(JsonRpcProvider)
    privateAccess(RpcHttpClient)
    let rpcClient = await provider.client
    let client: RpcHttpClient = (RpcHttpClient)(rpcClient)
    client.httpSession.connectTimeout = 10.millis

    let blockingSocket = newSocket()
    blockingSocket.setSockOpt(OptReuseAddr, true)
    blockingSocket.bindAddr(Port(9999))

    await client.connect("http://localhost:9999")

    expect RpcNetworkError:
      # msg: Failed to send POST Request with JSON-RPC: Connection timed out
      discard await provider.send("eth_accounts")

  # We don't need to recreate each and every possible exception condition, as
  # they are all wrapped up in RpcPostError and converted to RpcNetworkError.
  # The tests above cover this conversion.
