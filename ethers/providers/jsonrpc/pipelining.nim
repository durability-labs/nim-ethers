import pkg/json_rpc/client {.all.}
import pkg/json_rpc/errors
import pkg/chronos/apps/http/httpclient
import pkg/stew/byteutils
import ../../basics

type
  HttpPipeliningClient* = ref object of RpcClient
    session: HttpSessionRef
    address: HttpAddress
  HttpPipeliningOptions* = object
    idleTimeout*: Duration = 5.seconds

proc connect*(
  _: type HttpPipeliningClient,
  url: string,
  options = HttpPipeliningOptions()
): Future[HttpPipeliningClient] {.async: (raises: [CancelledError, JsonRpcError]).} =
  let session = HttpSessionRef.new(
    flags = {Http11Pipeline},
    idleTimeout = options.idleTimeout
  )
  let maybeAddress = session.getAddress(url)
  without address =? maybeAddress:
    raise newException(RpcAddressUnresolvableError, maybeAddress.error)
  HttpPipeliningClient(session: session, address: address)

proc post(
  client: HttpPipeliningClient,
  data: seq[byte]
): Future[HttpClientResponseRef] {.async: (raises: [CancelledError, JsonRpcError]).} =
  let request = HttpClientRequestRef.post(
    client.session,
    client.address,
    body = data,
    headers = @{"Content-Type": "application/json"}
  )

  var response: HttpClientResponseRef
  try:
    response = await request.send()
  except HttpError as error:
    raise newException(JsonRpcError, error.msg, error)
  finally:
    await request.closeWait()

  if response.status < 200 or response.status >= 300:
    let message = "HTTP status code " & $response.status & ": " & response.reason
    await response.closeWait()
    raise (ref ErrorResponse)(status: response.status, msg: message)

  response

method call*(
    client: HttpPipeliningClient, name: string, params: RequestParamsTx
): Future[JsonString] {.async.} =
  let id = client.getNextId()
  let data = cast[seq[byte]](requestTxEncode(name, params, id))
  let response = await client.post(data)
  let future = newFuture[JsonString]()
  client.awaiting[id] = future
  try:
    let body = await response.getBodyBytes()
    if error =? client.processMessage(string.fromBytes(body)).errorOption:
      raise newException(JsonRpcError, error)
  except HttpError as error:
    raise newException(JsonRpcError, error.msg, error)
  finally:
    client.awaiting.del(id)
    await response.closeWait()
  await future

method callBatch*(
    client: HttpPipeliningClient, calls: RequestBatchTx
): Future[ResponseBatchRx] {.async.} =
  let data = cast[seq[byte]](requestBatchEncode(calls))
  let response = await client.post(data)
  try:
    let body = await response.getBodyBytes()
    if error =? client.processMessage(string.fromBytes(body)).errorOption:
      raise newException(JsonRpcError, error)
  except HttpError as error:
    raise newException(JsonRpcError, error.msg, error)
  finally:
    await response.closeWait()
  await client.batchFut

method close*(client: HttpPipeliningClient) {.async: (raises: []).} =
  let session = client.session
  if session != nil:
    client.session = nil
    await session.closeWait()
