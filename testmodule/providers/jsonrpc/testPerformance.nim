import std/sequtils
import pkg/asynctest/chronos/unittest
import ethers

suite "JSON-RPC performance":

  test "can handle 50 000 concurrent connections":
    let provider = await JsonRpcProvider.connect("http://localhost:8545")
    let futures = newSeqWith(50_000, provider.getChainId())
    await allFutures(futures)
    check allIt(futures, it.completed)
    await provider.close()
