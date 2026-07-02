import pkg/json_rpc/rpcclient
import pkg/json_rpc/router
import ../../basics
import ../../subscriptions
import ./rpccalls
import ./errors

proc rpcRouter*(subscriptions: Subscriptions): ref RpcRouter =
  let router = RpcRouter.new()
  router[].rpc("eth_subscription") do() -> void:
    subscriptions.update()
  router

proc subscribeBlockNotifications*(
  websocket: RpcWebSocketClient
) {.async:(raises:[JsonRpcProviderError, CancelledError]).} =
  convertError:
    discard await websocket.eth_subscribe("newHeads")
