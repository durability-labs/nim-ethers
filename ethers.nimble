version = "3.3.1"
author = "Nim Ethers Authors"
description = "library for interacting with Ethereum"
license = "MIT"

requires "chronicles >= 0.10.3"
requires "chronos >= 4.0.4"
requires "https://github.com/durability-labs/nim-contract-abi >= 0.7.5"
requires "questionable >= 0.10.2"
requires "json_rpc >= 0.5.4"
requires "https://github.com/durability-labs/nim-serde >= 2.0.0"
requires "stew >= 0.2.0"
requires "eth >= 0.6.0"
requires "asynctest >= 0.5.4"

task test, "Tests":
  exec "nimble c -r testmodule/test.nim"
