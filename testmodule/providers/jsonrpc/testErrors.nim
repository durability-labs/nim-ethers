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
import pkg/websock/websock
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

type TestToken = ref object of Erc20Token

method mint(
  token: TestToken, holder: Address, amount: UInt256
): Confirmable {.base, contract.}

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

  proc testCustomResponse(
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

    let testNamePrefix =
      errorName & " error response is converted to " & errorType.name & " for "
    test testNamePrefix & "sending a manual RPC method request":
      registerRpcMethods(response)
      expect errorType:
        discard await provider.send("eth_accounts")

    test testNamePrefix &
      "calling a provider method that converts errors when calling a generated RPC request":
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
          Address.example,
          100.u256,
          TransactionOverrides(gasLimit: 100.u256.some, chainId: 1.u256.some),
        )

    test testNamePrefix & "sending a manual transaction":
      registerRpcMethods(response)
      expect errorType:
        let tx = Transaction.example
        discard await provider.getSigner().sendTransaction(tx)

    test testNamePrefix & "sending a raw transaction":
      registerRpcMethods(response)
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

    test testNamePrefix & "subscribing to blocks":
      registerRpcMethods(response)
      expect errorType:
        let emptyHandler = proc(blckResult: ?!Block) =
          discard
        discard await provider.subscribe(emptyHandler)

    test testNamePrefix & "subscribing to logs":
      registerRpcMethods(response)
      expect errorType:
        let filter =
          EventFilter(address: Address.example, topics: @[array[32, byte].example])
        let emptyHandler = proc(log: ?!Log) =
          discard
        discard await provider.subscribe(filter, emptyHandler)

  testCustomResponse("429", Http429, "Too many requests", HttpRequestLimitError)
  testCustomResponse("408", Http408, "Request timed out", HttpRequestTimeoutError)
  testCustomResponse("non-429", Http500, "Server error", JsonRpcProviderError)

  test "raises RpcNetworkError when reading response headers times out":
    privateAccess(JsonRpcProvider)
    privateAccess(RpcHttpClient)

    let responseTimeout = proc(
        request: HttpRequestRef
    ): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
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

# suite "Network errors - WebSocket":

#   var provider: JsonRpcProvider
#   var mockWsServer: MockWebSocketServer
#   var token: TestToken

#   setup:
#     mockWsServer = MockWebSocketServer.init(initTAddress("127.0.0.1:0"))
#     await mockWsServer.start()
#     # Get the actual bound address
#     let actualAddress = mockWsServer.localAddress()
#     provider = JsonRpcProvider.new("ws://" & $actualAddress & "/ws")

#     let deployment = readDeployment()
#     token = TestToken.new(!deployment.address(TestToken), provider)

#   teardown:
#     await provider.close()
#     await mockWsServer.stop()

#   proc registerRpcMethods(behavior: WebSocketBehavior) =
#     mockWsServer.registerRpcBehavior("eth_accounts", behavior)
#     mockWsServer.registerRpcBehavior("eth_call", behavior)
#     mockWsServer.registerRpcBehavior("eth_sendTransaction", behavior)
#     mockWsServer.registerRpcBehavior("eth_sendRawTransaction", behavior)
#     mockWsServer.registerRpcBehavior("eth_newBlockFilter", behavior)
#     mockWsServer.registerRpcBehavior("eth_newFilter", behavior)
#     mockWsServer.registerRpcBehavior("eth_subscribe", behavior)

#   proc testCustomBehavior(errorName: string, behavior: WebSocketBehavior, errorType: type CatchableError) =
#     let testNamePrefix = errorName & " behavior is converted to " & errorType.name & " for "

#     test testNamePrefix & "sending a manual RPC method request":
#       registerRpcMethods(behavior)
#       expect errorType:
#         discard await provider.send("eth_accounts")

#     test testNamePrefix & "calling a provider method that converts errors":
#       registerRpcMethods(behavior)
#       expect errorType:
#         discard await provider.listAccounts()

#     test testNamePrefix & "calling a view method of a contract":
#       registerRpcMethods(behavior)
#       expect errorType:
#         discard await token.balanceOf(Address.example)

#     test testNamePrefix & "calling a contract method that executes a transaction":
#       registerRpcMethods(behavior)
#       expect errorType:
#         token = TestToken.new(token.address, provider.getSigner())
#         discard await token.mint(
#           Address.example, 100.u256,
#           TransactionOverrides(gasLimit: 100.u256.some, chainId: 1.u256.some)
#         )

#     test testNamePrefix & "sending a manual transaction":
#       registerRpcMethods(behavior)
#       expect errorType:
#         let tx = Transaction.example
#         discard await provider.getSigner().sendTransaction(tx)

#     test testNamePrefix & "sending a raw transaction":
#       registerRpcMethods(behavior)
#       expect errorType:
#         const pk_with_funds = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
#         let wallet = !Wallet.new(pk_with_funds)
#         let tx = Transaction(
#           to: wallet.address,
#           nonce: some 0.u256,
#           chainId: some 31337.u256,
#           gasPrice: some 1_000_000_000.u256,
#           gasLimit: some 21_000.u256,
#         )
#         let signedTx = await wallet.signTransaction(tx)
#         discard await provider.sendTransaction(signedTx)

#     test testNamePrefix & "subscribing to blocks":
#       registerRpcMethods(behavior)
#       expect errorType:
#         let emptyHandler = proc(blckResult: ?!Block) = discard
#         discard await provider.subscribe(emptyHandler)

#     test testNamePrefix & "subscribing to logs":
#       registerRpcMethods(behavior)
#       expect errorType:
#         let filter = EventFilter(address: Address.example, topics: @[array[32, byte].example])
#         let emptyHandler = proc(log: ?!Log) = discard
#         discard await provider.subscribe(filter, emptyHandler)

#   # WebSocket close codes equivalent to HTTP status codes
#   testCustomBehavior(
#     "Policy violation close (rate limit)",
#     createBehavior(CloseWithCode, StatusPolicyError, "Policy violation - rate limited"),
#     WebSocketPolicyError
#   )

#   testCustomBehavior(
#     "Server error close",
#     createBehavior(CloseWithCode, StatusUnexpectedError, "Internal server error"),
#     JsonRpcProviderError
#   )

#   # testCustomBehavior(
#   #   "Service unavailable close",
#   #   createBehavior(CloseWithCode, StatusCodes.TryAgainLater, "Try again later"),
#   #   WebSocketServiceUnavailableError
#   # )

#   testCustomBehavior(
#     "Abrupt disconnect",
#     createBehavior(AbruptClose),
#     RpcNetworkError
#   )

#   test "raises RpcNetworkError when WebSocket connection times out":
#     registerRpcMethods(createBehavior(Timeout, delay = 5.minutes))

#     # Set a short timeout on the WebSocket client
#     privateAccess(JsonRpcProvider)
#     privateAccess(RpcWebSocketClient)

#     let rpcClient = await provider.client
#     let client = RpcWebSocketClient(rpcClient)
#     # Note: Actual timeout setting depends on nim-websock implementation
#     # This may need to be adjusted based on available APIs

#     expect RpcNetworkError:
#       discard await provider.send("eth_accounts").wait(1.seconds)

#   test "raises RpcNetworkError when WebSocket connection is closed unexpectedly":
#     # Start a request, then close the server
#     let sendFuture = provider.send("eth_accounts")
#     await sleepAsync(10.millis)
#     await mockWsServer.stop()

#     expect RpcNetworkError:
#       discard await sendFuture

#   test "raises RpcNetworkError when WebSocket connection fails to establish":
#     # Stop the server first
#     await mockWsServer.stop()

#     expect RpcNetworkError:
#       let deadProvider = JsonRpcProvider.new("ws://127.0.0.1:9999/ws")
#       discard await deadProvider.send("eth_accounts")

#   test "handles WebSocket protocol errors gracefully":
#     registerRpcMethods(createBehavior(InvalidFrame))

#     expect JsonRpcProviderError: # or whatever error nim-json-rpc maps protocol errors to
#       discard await provider.send("eth_accounts")

#   test "handles oversized WebSocket messages":
#     registerRpcMethods(createBehavior(MessageTooBig))

#     expect RpcNetworkError: # Large message handling depends on client limits
#       discard await provider.send("eth_accounts")

#   test "raises timeout error on slow WebSocket handshake":
#     # Create a server that delays the WebSocket upgrade
#     let slowServer = MockWebSocketServer.init(initTAddress("127.0.0.1:0"))
#     # This would need custom implementation to delay handshake

#     expect WebSocketTimeoutError:
#       let slowProvider = JsonRpcProvider.new("ws://127.0.0.1:9998/ws")
#       discard await slowProvider.send("eth_accounts").wait(100.millis)

#   test "handles connection drops during message exchange":
#     # Register normal behavior initially
#     registerRpcMethods(createBehavior(Normal))

#     # Start multiple requests
#     let futures = @[
#       provider.send("eth_accounts"),
#       provider.send("eth_call"),
#       provider.send("eth_newBlockFilter")
#     ]

#     # Close connections after a short delay
#     await sleepAsync(5.millis)
#     for conn in mockWsServer.connections:
#       await conn.close(StatusCodes.AbnormalClosure, "Abnormal closure")

#     # All should fail with network error
#     for future in futures:
#       expect RpcNetworkError:
#         discard await future

#   test "recovers from temporary WebSocket disconnections":
#     # This test would verify client reconnection logic if implemented
#     # Initial connection works
#     registerRpcMethods(createBehavior(Normal))
#     let result1 = await provider.send("eth_accounts")
#     check result1.isOk

#     # Simulate connection drop
#     for conn in mockWsServer.connections:
#       await conn.close(StatusCodes.GoingAway, "Going away")

#     # Depending on provider implementation, this might auto-reconnect
#     # or need manual reconnection
#     expect RpcNetworkError:
#       discard await provider.send("eth_accounts")

#   test "handles WebSocket ping/pong timeouts":
#     # This would test the ping/pong mechanism if the client supports it
#     registerRpcMethods(createBehavior(Normal))

#     # Mock a scenario where server doesn't respond to pings
#     for conn in mockWsServer.connections:
#       # Disable pong responses (if we had access to this)
#       conn.onPing = nil

#     # This test would need to trigger ping timeout
#     # The exact implementation depends on the websocket client capabilities

#   test "handles WebSocket close frame with invalid payload":
#     # Test handling of malformed close frames
#     registerRpcMethods(createBehavior(CloseWithCode, StatusCodes.ProtocolError, ""))

#     expect JsonRpcProviderError:
#       discard await provider.send("eth_accounts")
