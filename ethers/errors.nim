import pkg/websock/websock
import pkg/json_rpc/errors
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
  WebsocketConnectionError* = object of RpcNetworkError

{.push raises: [].}

template convertErrorsTo*(newErrorType: type, body) =
  try:
    body
  except CancelledError as error:
    raise error
  except RpcNetworkError as error:
    raise error
  except RpcPostError as error:
    raiseNetworkError(error)
  except FailedHttpResponse as error:
    raiseNetworkError(error)
  except HttpError as error: # from websock.common
    # eg Timeout expired while receiving headers
    # eg Unable to connect to host on any address!
    # eg No connection to host!
    raise newException(WebsocketConnectionError, error.msg, error)
  except WSClosedError as error:
    raise newException(WebsocketConnectionError, error.msg, error)
  except ErrorResponse as error:
    if error.status == 429:
      raise newException(HttpRequestLimitError, error.msg, error)
    elif error.status == 408:
      raise newException(HttpRequestTimeoutError, error.msg, error)
    else:
      raise newException(newErrorType, error.msg, error)
  except JsonRpcError as error:
    var message = error.msg
    if jsn =? JsonNode.fromJson(message):
      if "message" in jsn:
        message = jsn{"message"}.getStr
    raise newException(newErrorType, message, error)
  except CatchableError as error:
    raise newException(newErrorType, error.msg, error)

proc toErr*[E1: ref CatchableError, E2: EthersError](
    e1: E1, _: type E2, msg: string = e1.msg
): ref E2 =
  return newException(E2, msg, e1)

proc raiseNetworkError*(error: ref CatchableError) {.raises: [RpcNetworkError].} =
  raise newException(RpcNetworkError, error.msg, error)
