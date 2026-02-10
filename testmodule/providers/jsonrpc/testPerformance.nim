import std/sequtils
import pkg/asynctest/chronos/unittest
import ethers

suite "JSON-RPC performance":

  test "can handle 50 000 simultaneous connections by limiting concurrency":
    let options = JsonRpcOptions(httpConcurrencyLimit: some 100)
    let provider = await JsonRpcProvider.connect("http://localhost:8545", options)
    let futures = newSeqWith(50_000, provider.getBlockNumber())
    await allFutures(futures)
    check allIt(futures, it.completed)
    await provider.close()
