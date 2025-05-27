import ../../../examples
import ../../../../ethers/provider
import ../../../../ethers/providers/jsonrpc/conversions

import std/sequtils
import pkg/stew/byteutils
import pkg/json_rpc/rpcserver except `%`, `%*`
import pkg/json_rpc/errors
import ./mockRpcHttpServer

export mockRpcHttpServer

{.push raises: [].}

type MockRpcHttpServerSubscriptions* = ref object of MockRpcHttpServer
  filters*: seq[string]
  nextGetChangesReturnsError*: bool

proc new*(_: type MockRpcHttpServerSubscriptions): MockRpcHttpServerSubscriptions {.raises: [JsonRpcError].} =
  let srv = newRpcHttpServer(["127.0.0.1:0"])
  MockRpcHttpServerSubscriptions(filters: @[], srv: srv, nextGetChangesReturnsError: false)

proc invalidateFilter*(server: MockRpcHttpServerSubscriptions, jsonId: JsonNode) =
  server.filters.keepItIf it != jsonId.getStr

method start*(server: MockRpcHttpServerSubscriptions) =
  server.registerRpcMethod("eth_newFilter") do(filter: EventFilter) -> string:
    let filterId = "0x" & (array[16, byte].example).toHex
    server.filters.add filterId
    return filterId

  server.registerRpcMethod("eth_newBlockFilter") do() -> string:
    let filterId = "0x" & (array[16, byte].example).toHex
    server.filters.add filterId
    return filterId

  server.registerRpcMethod("eth_getFilterChanges") do(id: string) -> seq[string]:
    if server.nextGetChangesReturnsError:
          raise (ref ApplicationError)(code: -32000, msg: "unknown error")

    if id notin server.filters:
      raise (ref ApplicationError)(code: -32000, msg: "filter not found")

    return @[]

  server.registerRpcMethod("eth_uninstallFilter") do(id: string) -> bool:
    if id notin server.filters:
      raise (ref ApplicationError)(code: -32000, msg: "filter not found")

    server.invalidateFilter(%id)
    return true

  procCall MockRpcHttpServer(server).start()
