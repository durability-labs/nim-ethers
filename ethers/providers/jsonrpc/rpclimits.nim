import std/deques
import pkg/json_rpc/client {.all.}
import pkg/json_rpc/errors
import pkg/chronos

type LimitedRpcClient* = ref object of RpcClient
  wrapped: RpcClient
  concurrencyLimit: int
  concurrency: int
  waiting: Deque[Future[void].Raising([CancelledError])]

func limited*(client: RpcClient, concurrency: int): LimitedRpcClient =
  LimitedRpcClient(
    wrapped: client,
    concurrencyLimit: concurrency,
    waiting: initDeque[Future[void].Raising([CancelledError])](),
  )

proc increaseConcurrency(client: LimitedRpcClient) {.async: (raises: [CancelledError]).} =
  if client.concurrency + 1 > client.concurrencyLimit:
    let waiting = Future[void].Raising([CancelledError]).init()
    client.waiting.addLast(waiting)
    await waiting
  inc client.concurrency

proc decreaseConcurrency(client: LimitedRpcClient) =
  dec client.concurrency
  if client.waiting.len > 0:
    client.waiting.popFirst().complete()

method send(
    client: LimitedRpcClient, data: seq[byte]
) {.async: (raises: [CancelledError, JsonRpcError]).} =
  try:
    await client.increaseConcurrency()
    await client.wrapped.send(data)
  finally:
    client.decreaseConcurrency()

method request(
    client: LimitedRpcClient, reqData: seq[byte]
): Future[seq[byte]] {.async: (raises: [CancelledError, JsonRpcError]).} =
  try:
    await client.increaseConcurrency()
    await client.wrapped.request(reqData)
  finally:
    client.decreaseConcurrency()

method close*(client: LimitedRpcClient): Future[void] {.async: (raises: []).} =
  await client.wrapped.close()
