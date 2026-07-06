import std/importutils
import pkg/asynctest/chronos/unittest
import pkg/json_rpc/client
import ethers
import ethers/providers/jsonrpc

suite "JSON-RPC websocket reconnecting":

  test "reconnects when socket is closed unexpectedly":
    let provider = await JsonRpcProvider.connect("ws://localhost:8545")
    privateAccess JsonRpcProvider
    await provider.client.close()
    discard await provider.getBlockNumber() # should not raise exception

  test "does not reconnect when the provider is explicitly closed":
    let provider = await JsonRpcProvider.connect("ws://localhost:8545")
    await provider.close()
    expect JsonRpcProviderError:
      discard await provider.getBlockNumber()
