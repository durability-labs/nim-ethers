import std/strutils
import pkg/stew/byteutils
import ../../basics
import ../../errors
import ../../provider
import ./conversions

export errors

{.push raises:[].}

type JsonRpcProviderError* = object of ProviderError

func extractErrorData(json: JsonNode): ?seq[byte] =
  if json.kind == JObject:
    if "message" in json and "data" in json:
      let message = json{"message"}.getStr()
      let hex = json{"data"}.getStr()
      if "reverted" in message and hex.startsWith("0x"):
        if data =? hexToSeqByte(hex).catch:
          return some data
    for key in json.keys:
      if data =? extractErrorData(json{key}):
        return some data

func new*(_: type JsonRpcProviderError, json: JsonNode): ref JsonRpcProviderError =
  let error = (ref JsonRpcProviderError)()
  if "message" in json:
    error.msg = json{"message"}.getStr
  error.data = extractErrorData(json)
  error

proc raiseJsonRpcProviderError*(
  error: ref CatchableError, message = error.msg) {.raises: [JsonRpcProviderError].} =
  if json =? JsonNode.fromJson(error.msg):
    raise JsonRpcProviderError.new(json)
  else:
    raise newException(JsonRpcProviderError, message)

proc underlyingErrorOf(e: ref Exception, T: type CatchableError): (ref CatchableError) =
  if e of (ref T):
    return (ref T)(e)
  elif not e.parent.isNil:
    return e.parent.underlyingErrorOf T
  else:
    return nil

template convertError*(body) =
  try:
    try:
      body
    # Inspect SubscriptionErrors and re-raise underlying JsonRpcErrors so that
    # exception inspection and resolution only needs to happen once. All
    # CatchableErrors that occur in the Subscription module are converted to
    # SubscriptionError, with the original error preserved as the exception's
    # parent.
    except SubscriptionError, SignerError:
      let e = getCurrentException()
      let parent = e.underlyingErrorOf(JsonRpcError)
      if not parent.isNil:
        raise parent
  except CancelledError as error:
    raise error
  except RpcPostError as error:
    raiseNetworkError(error)
  except FailedHttpResponse as error:
    raiseNetworkError(error)
  except ErrorResponse as error:
    if error.status == 429:
      raise newException(HttpRequestLimitError, error.msg, error)
    elif error.status == 408:
      raise newException(HttpRequestTimeoutError, error.msg, error)
    else:
      raiseJsonRpcProviderError(error)
  except JsonRpcError as error:
    var message = error.msg
    if jsn =? JsonNode.fromJson(message):
      if "message" in jsn:
        message = jsn{"message"}.getStr
    raiseJsonRpcProviderError(error, message)
  except CatchableError as error:
    raiseJsonRpcProviderError(error)

