import std/os
import pkg/asynctest/chronos/unittest
import pkg/json_rpc/rpcclient
import pkg/json_rpc/rpcserver
import ethers/providers/jsonrpc

for (scheme, pipelining) in [("ws", false), ("http", false), ("http", true)]:

  suite "JSON RPC subscriptions (" & scheme & ", pipelining: " & $pipelining & ")":

    let url = scheme & "://" & getEnv("ETHERS_TEST_PROVIDER", "localhost:8545")
    var provider: JsonRpcProvider

    setup:
      var options = JsonRpcOptions()
      options.httpPipelining = pipelining
      options.pollingInterval = 100.milliseconds
      provider = await JsonRpcProvider.connect(url, options)

    teardown:
      await provider.close()

    test "subscribes to new blocks":
      var latestBlock: Block
      proc callback(blck: Block) =
        latestBlock = blck
      let subscription = await provider.subscribe(callback)
      discard await provider.send("evm_mine")
      check eventually latestBlock.number.isSome
      check latestBlock.hash.isSome
      check latestBlock.timestamp > 0.u256
      await subscription.unsubscribe()

    test "stops listening to new blocks when unsubscribed":
      var count = 0
      proc callback(blck: Block) =
        inc count
      let subscription = await provider.subscribe(callback)
      discard await provider.send("evm_mine")
      check eventually count > 0
      await subscription.unsubscribe()
      count = 0
      discard await provider.send("evm_mine")
      await sleepAsync(200.millis)
      check count == 0

    test "duplicate unsubscribe is harmless":
      proc callback(blck: Block) = discard
      let subscription = await provider.subscribe(callback)
      await subscription.unsubscribe()
      await subscription.unsubscribe()

    test "stops listening to new blocks when provider is closed":
      var count = 0
      proc callback(blck: Block) =
        inc count
      discard await provider.subscribe(callback)
      discard await provider.send("evm_mine")
      check eventually count > 0
      await provider.close()
      count = 0
      provider = await JsonRpcProvider.connect(url, pollingInterval = 100.millis)
      discard await provider.send("evm_mine")
      await sleepAsync(200.millis)
      check count == 0

suite "JSON-RPC websocket subscription updates":

  test "uses websocket notifications of new blocks":
    let url = "ws://" & getEnv("ETHERS_TEST_PROVIDER", "localhost:8545")
    let options = JsonRpcOptions(pollingInterval: 100.days) # disable polling
    let provider = await JsonRpcProvider.connect(url, options)
    var called = false
    proc callback(_: Block) =
      called = true
    let subscription = await provider.subscribe(callback)
    discard await provider.send("evm_mine")
    check eventually called
    await subscription.unsubscribe()
