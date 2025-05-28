import std/tables
import pkg/serde
import pkg/chronos/apps/http/httpclient
import pkg/chronos/apps/http/httpserver
import pkg/stew/byteutils
import pkg/questionable

export httpserver

{.push raises: [].}

type
  RpcResponse* = proc(request: HttpRequestRef): Future[HttpResponseRef] {.async: (raises: [CancelledError]), raises: [].}

  MockHttpServer* = object
    server: HttpServerRef
    rpcResponses: ref Table[string, RpcResponse]

  RequestRx {.deserialize.} = object
    jsonrpc*: string
    id*     : int
    `method`* : string


proc init*(_: type MockHttpServer, address: TransportAddress): MockHttpServer =
  var server: MockHttpServer

  proc processRequest(r: RequestFence): Future[HttpResponseRef] {.async: (raises: [CancelledError]).} =
    if r.isErr:
      return defaultResponse()

    let request = r.get()
    try:
      let body = string.fromBytes(await request.getBody())
      echo "mockHttpServer.processRequest request: ", body
      without req =? RequestRx.fromJson(body), error:
        echo "failed to deserialize, error: ", error.msg
        return await request.respond(Http400, "Invalid request, must be valid json rpc request")

      echo "Received request with method: ", req.method
      if not server.rpcResponses.contains(req.method):
        return await request.respond(Http404, "Method not registered")

      try:
        let rpcResponseProc = server.rpcResponses[req.method]
        return await rpcResponseProc(request)
      except KeyError as e:
        return await request.respond(Http500, "Method lookup error with key, error: " & e.msg)

    except HttpProtocolError as e:
      echo "HttpProtocolError encountered, error: ", e.msg
      return defaultResponse(e)
    except HttpTransportError as e:
      echo "HttpTransportError encountered, error: ", e.msg
      return defaultResponse(e)
    except HttpWriteError as exc:
      return defaultResponse(exc)

  let
    socketFlags = {ServerFlags.TcpNoDelay, ServerFlags.ReuseAddr}
    serverFlags = {HttpServerFlags.Http11Pipeline}
    res = HttpServerRef.new(address, processRequest,
                                socketFlags = socketFlags,
                                serverFlags = serverFlags)
  server = MockHttpServer(server: res.get(), rpcResponses: newTable[string, RpcResponse]())
  return server

template registerRpcResponse*(server: MockHttpServer, `method`: string, rpcResponse: untyped): untyped =
  server.rpcResponses[`method`] = rpcResponse

proc address*(server: MockHttpServer): TransportAddress =
  server.server.instance.localAddress()

proc start*(server: MockHttpServer) =
  server.server.start()

proc stop*(server: MockHttpServer) {.async: (raises: []).} =
  await server.server.stop()
  await server.server.closeWait()

