import pkg/json_rpc/client {.all.}
import pkg/json_rpc/errors
import pkg/chronos/apps/http/httpclient
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
    raise newException(RpcTransportError, error.msg, error)
  finally:
    await request.closeWait()

  if response.status < 200 or response.status >= 300:
    let message = "HTTP status code " & $response.status & ": " & response.reason
    await response.closeWait()
    raise (ref ErrorResponse)(status: response.status, msg: message)

  response

method send(
    client: HttpPipeliningClient, data: seq[byte]
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  let response = await client.post(data)
  await response.closeWait()

method request(
    client: HttpPipeliningClient, data: seq[byte]
): Future[seq[byte]] {.async: (raises: [CancelledError, JsonRpcError]).} =
  let response = await client.post(data)
  try:
    await response.getBodyBytes()
  except HttpError as error:
    raise newException(RpcTransportError, error.msg, error)
  finally:
    await response.closeWait()

method close*(client: HttpPipeliningClient) {.async: (raises: []).} =
  let session = client.session
  if session != nil:
    client.session = nil
    await session.closeWait()
