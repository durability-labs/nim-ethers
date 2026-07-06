import pkg/chronos

template withLock*(lock: AsyncLock, body: untyped): untyped =
  await lock.acquire()
  try:
    body
  finally:
    try:
      lock.release()
    except AsyncLockError as error:
      raiseAssert error.msg
