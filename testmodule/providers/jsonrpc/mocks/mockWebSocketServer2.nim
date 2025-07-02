import std/tables
import std/strutils
import std/uri
  # pkg/chronos,
import pkg/chronicles
  # pkg/chronos/apps/http/httpserver,
import pkg/websock/websock
import pkg/websock/tests/helpers
import pkg/httputils
import pkg/asynctest/chronos/unittest
    # json_rpc/clients/websocketclient,
  # json_rpc/[client, server],
  # json_serialization

import pkg/stew/byteutils
import pkg/ethers

const address = initTAddress("127.0.0.1:8888")

proc handle(request: HttpRequest) {.async.} =
    check request.uri.path == WSPath

    let server = WSServer.new(protos = ["proto"])
    let ws = await server.handleRequest(request)
    let servRes = await ws.recvMsg()

    check string.fromBytes(servRes) == testString
    await ws.waitForClose()


proc run() {.async.} =

  let server = createServer(
    address = address,
    handler = handle,
    flags = {ReuseAddr})

  let provider = JsonRpcProvider.new("ws://" & $address)