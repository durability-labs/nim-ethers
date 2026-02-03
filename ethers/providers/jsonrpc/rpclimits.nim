import std/deques
import pkg/json_rpc/client
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

method call*(
    client: LimitedRpcClient, name: string, params: RequestParamsTx
): Future[JsonString] {.async.} =
  try:
    await client.increaseConcurrency()
    await client.wrapped.call(name, params)
  finally:
    client.decreaseConcurrency()

method close*(client: LimitedRpcClient) {.async.} =
  await client.wrapped.close()

method callBatch*(
    client: LimitedRpcClient, calls: RequestBatchTx
): Future[ResponseBatchRx] {.async.} =
  try:
    await client.increaseConcurrency()
    await client.wrapped.callBatch(calls)
  finally:
    client.decreaseConcurrency()
