version = "3.1.1"
author = "Nim Ethers Authors"
description = "library for interacting with Ethereum"
license = "MIT"

requires "chronicles >= 0.10.3"
requires "chronos >= 4.0.4 & < 4.1.0"
requires "https://github.com/durability-labs/nim-contract-abi >= 0.7.4 & < 0.8.0"
requires "questionable >= 0.10.2 & < 0.11.0"
requires "json_rpc >= 0.5.0 & < 0.6.0"
requires "https://github.com/durability-labs/nim-serde >= 2.0.0 & < 3.0.0"
requires "stint >= 0.8.1 & < 0.9.0"
requires "stew >= 0.2.0"
requires "eth >= 0.5.0 & < 0.6.0"

taskRequires "test", "asynctest >= 0.5.4 & < 0.6.0"

task test, "Tests":
  exec "nimble c -r testmodule/test.nim"
