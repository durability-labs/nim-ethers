import std/sequtils
import pkg/asynctest/chronos/unittest
import ethers
import ethers/erc20
import ../../hardhat

type TestToken = ref object of Erc20Token

suite "JSON-RPC performance (websockets)":

  test "can call several contract functions in parallel":
    let provider = await JsonRpcProvider.connect("ws://localhost:8545")
    let deployment = readDeployment()
    let token = TestToken.new(!deployment.address(TestToken), provider)
    let futures = newSeqWith(100, token.decimals())
    await allFutures(futures)
    for future in futures:
      discard await future
    await provider.close()

suite "JSON-RPC performance (http)":

  test "can handle 50 000 simultaneous connections by limiting concurrency":
    let options = JsonRpcOptions(httpConcurrencyLimit: some 100)
    let provider = await JsonRpcProvider.connect("http://localhost:8545", options)
    let futures = newSeqWith(50_000, provider.getBlockNumber())
    await allFutures(futures)
    check allIt(futures, it.completed)
    await provider.close()

  test "can handle 50 000 simultaneous connections using HTTP pipelining":
    let options = JsonRpcOptions(httpConcurrencyLimit: some 100, httpPipelining: true)
    let provider = await JsonRpcProvider.connect("http://localhost:8545", options)
    let futures = newSeqWith(50_000, provider.getBlockNumber())
    await allFutures(futures)
    check allIt(futures, it.completed)
    await provider.close()
