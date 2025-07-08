import std/tables
import std/sequtils
import pkg/chronos
import pkg/chronicles except toJson, `%`, `%*`
import pkg/websock/websock except toJson, `%`, `%*`
import pkg/json_rpc/clients/websocketclient except toJson, `%`, `%*`
import pkg/json_rpc/client except toJson, `%`, `%*`
import pkg/json_rpc/server except toJson, `%`, `%*`
import pkg/questionable
import pkg/websock/http/common
import pkg/serde
import pkg/stew/byteutils

type
  MockWebSocketServer* = ref object
    httpServer: HttpServer
    address*: TransportAddress
    connections: seq[WSSession]
    rpcResponses: Table[string, WebSocketResponse]
    running: bool

  WebSocketResponse* = proc(ws: WSSession) {.async.}

  RequestRx {.deserialize.} = object
    jsonrpc*: string
    id*: int
    `method`*: string

  ResponseKind* = enum
    rkResult
    rkError

  ResponseError* {.serialize.} = object
    code*: int
    message*: string
    data*: ?string

  ResponseTx* {.serialize.} = object
    jsonrpc*: string
    id*: int
    case kind* {.serialize(ignore = true).}: ResponseKind
    of rkResult:
      result*: JsonNode
    of rkError:
      error*: ResponseError

proc init*(T: type MockWebSocketServer, address: TransportAddress): T =
  T(
    address: address,
    connections: @[],
    rpcResponses: initTable[string, WebSocketResponse](),
    running: false,
  )

proc registerRpcResponse*(
    server: MockWebSocketServer, `method`: string, response: WebSocketResponse
) =
  server.rpcResponses[`method`] = response

proc handleWebSocketConnection(server: MockWebSocketServer, ws: WSSession) {.async.} =
  server.connections.add(ws)

  try:
    while ws.readyState == ReadyState.Open:
      let data = await ws.recvMsg()
      let message = string.fromBytes(data)

      without request =? RequestRx.fromJson(message), error:
        await ws.close(StatusProtocolError, "Invalid JSON")
        break

      if request.method notin server.rpcResponses:
        let response = ResponseTx(
          jsonrpc: "2.0",
          id: request.id,
          kind: rkError,
          error: ResponseError(code: 404, message: "Method not registered"),
        )
        await ws.send(response.toJson())
        break

      let rpcResponseProc = server.rpcResponses[request.method]

      await ws.rpcResponseProc()
  except WSClosedError:
    # Connection was closed
    trace "WebSocket connection closed"
  except CatchableError as exc:
    trace "WebSocket connection error", error = exc.msg

proc processRequest(server: MockWebSocketServer, request: HttpRequest) {.async.} =
  let wsServer = WSServer.new(protos = ["proto"])
  # perform upgrade
  let ws = await wsServer.handleRequest(request)
  await server.handleWebSocketConnection(ws)

proc start*(server: MockWebSocketServer) {.async.} =
  if server.running:
    return

  let handler = proc(request: HttpRequest): Future[void] {.async, raises: [].} =
    await server.processRequest(request)

  server.httpServer =
    HttpServer.create(address = server.address, handler = handler, flags = {ReuseAddr})
  server.httpServer.start()
  server.running = true

proc stop*(server: MockWebSocketServer) {.async.} =
  if not server.running:
    return

  server.running = false

  # Close all active connections
  for conn in server.connections:
    if conn.readyState == ReadyState.Open:
      await conn.close(StatusGoingAway, "Server shutting down")

  server.connections.setLen(0)

  if not server.httpServer.isNil:
    server.httpServer.stop()

proc localAddress*(server: MockWebSocketServer): TransportAddress =
  if server.httpServer.isNil:
    return server.address
  return server.httpServer.localAddress()
