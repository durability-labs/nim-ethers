import pkg/json_rpc/rpcserver except `%`, `%*`
import pkg/json_rpc/servers/httpserver
import ./mockRpcServer

{.push raises: [].}

type MockRpcHttpServer* = ref object of MockRpcServer

proc new*(_: type MockRpcHttpServer): MockRpcHttpServer {.raises: [JsonRpcError].} =
  let srv = newRpcHttpServer(initTAddress("127.0.0.1:0"))
  MockRpcHttpServer(srv: srv)

template registerRpcMethod*(
    server: MockRpcHttpServer, path: string, body: untyped
): untyped =
  server.srv.router.rpc(path, body)

method start*(server: MockRpcHttpServer) {.gcsafe, raises: [JsonRpcError].} =
  RpcHttpServer(server.srv).start()

method stop*(server: MockRpcHttpServer) {.async: (raises: []).} =
  try:
    await RpcHttpServer(server.srv).stop()
    await RpcHttpServer(server.srv).closeWait()
  except CatchableError:
    # stop and closeWait don't actually raise but they're not annotated with
    # raises: []
    discard

method localAddress*(server: MockRpcHttpServer): TransportAddress =
  return RpcHttpServer(server.srv).localAddress()[0]
