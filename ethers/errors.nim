import ./basics

type
  SolidityError* = object of EthersError
  ContractError* = object of EthersError
  SignerError* = object of EthersError
  SubscriptionError* = object of EthersError
  ProviderError* = object of EthersError
    data*: ?seq[byte]
  RpcNetworkError* = object of EthersError
  RpcHttpErrorResponse* = object of RpcNetworkError
  HttpRequestLimitError* = object of RpcHttpErrorResponse
  HttpRequestTimeoutError* = object of RpcHttpErrorResponse

{.push raises:[].}

proc toErr*[E1: ref CatchableError, E2: EthersError](
  e1: E1,
  _: type E2,
  msg: string = e1.msg): ref E2 =

  return newException(E2, msg, e1)

proc raiseNetworkError*(
  error: ref CatchableError) {.raises: [RpcNetworkError].} =
  raise newException(RpcNetworkError, error.msg, error)
