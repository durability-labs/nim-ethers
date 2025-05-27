import ../../../examples
import ../../../../ethers/provider
import ../../../../ethers/providers/jsonrpc/conversions

import std/sequtils
import pkg/stew/byteutils
import pkg/json_rpc/rpcserver except `%`, `%*`
import pkg/json_rpc/errors

{.push raises: [].}

type MockRpcHttpServer* = ref object of RootObj
  srv: RpcHttpServer

proc new*(_: type MockRpcHttpServer): MockRpcHttpServer {.raises: [JsonRpcError].} =
  let srv = newRpcHttpServer(["127.0.0.1:0"])
  MockRpcHttpServer(srv: srv)


template registerRpcMethod*(server: MockRpcHttpServer, path: string, body: untyped): untyped =
  server.srv.router.rpc(path, body)

method start*(server: MockRpcHttpServer) {.gcsafe, base.} =
  server.srv.start()

proc stop*(server: MockRpcHttpServer) {.async.} =
  await server.srv.stop()
  await server.srv.closeWait()

proc localAddress*(server: MockRpcHttpServer): seq[TransportAddress] =
  return server.srv.localAddress()
