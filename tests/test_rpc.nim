import std/unittest
import neonim/rpc
import msgpack4nim

suite "neovim msgpack rpc":
  test "request encode/decode":
    var session = initRpcSession()
    let (id, data) = startRequest(session, "vim_get_api_info", rpcPackParams())
    check id == 1
    let pending = pendingRequests(session)
    check pending.len == 1
    check pending[0] == id

    var parser = initRpcParser()
    let messages = parser.feed(data)
    check messages.len == 1
    let msg = messages[0]
    check msg.kind == rmRequest
    check msg.msgid == 1
    check msg.methodName == "vim_get_api_info"
    let params = rpcUnpack[seq[int]](msg.params)
    check params.len == 0

  test "response encode/decode":
    let data = sendResponse(3, rpcPackNil(), rpcPack("ok"))
    var parser = initRpcParser()
    let messages = parser.feed(data)
    check messages.len == 1
    let msg = messages[0]
    check msg.kind == rmResponse
    check msg.msgid == 3
    check msg.error.isNilValue
    check rpcUnpack[string](msg.result) == "ok"

  test "notification encode/decode":
    let data = sendNotification("redraw", rpcPackParams(1, 2))
    var parser = initRpcParser()
    let messages = parser.feed(data)
    check messages.len == 1
    let msg = messages[0]
    check msg.kind == rmNotification
    check msg.methodName == "redraw"
    let params = rpcUnpack[seq[int]](msg.params)
    check params.len == 2
    check params[0] == 1
    check params[1] == 2

  test "incremental parse":
    let data = sendNotification("incremental", rpcPackParams("ok"))
    let mid = data.len div 2
    var parser = initRpcParser()
    check parser.feed(data[0 ..< mid]).len == 0
    let messages = parser.feed(data[mid .. ^1])
    check messages.len == 1
    check messages[0].methodName == "incremental"

  test "router rpc macro":
    var router = newRpcRouter()
    proc add(a: int, b: int): int {.rpc.} =
      a + b

    let req = newRequest(42, "add", rpcPackParams(7, 5))
    let resp = router.callMethod(req)
    check resp.kind == rmResponse
    check resp.msgid == 42
    check resp.error.isNilValue
    check rpcUnpack[int](resp.result) == 12

  test "client rpc macros":
    proc vim_get_api_info(session: var RpcSession): RpcMessage {.rpcRequest.}
    proc redraw(a: int, b: int): RpcMessage {.rpcNotify.}

    var session = initRpcSession()
    let reqMsg = vim_get_api_info(session)
    check reqMsg.msgid == 1
    check reqMsg.kind == rmRequest
    check reqMsg.methodName == "vim_get_api_info"
    let reqParams = rpcUnpack[seq[int]](reqMsg.params)
    check reqParams.len == 0

    let notifMsg = redraw(3, 4)
    check notifMsg.kind == rmNotification
    check notifMsg.methodName == "redraw"
    let notifParams = rpcUnpack[seq[int]](notifMsg.params)
    check notifParams.len == 2
    check notifParams[0] == 3
    check notifParams[1] == 4

  test "rpc round trip":
    var router = newRpcRouter()
    proc add(a: int, b: int): int {.rpc.} =
      a + b
    proc add(session: var RpcSession, a: int, b: int): RpcMessage {.rpcClient.}

    var session = initRpcSession()
    let reqMsg = add(session, 2, 3)

    let respMsg = router.callMethod(reqMsg)
    check rpcUnpack[int](respMsg.result) == 5
    check completeRequest(session, respMsg.msgid)

  test "invalid frame errors":
    var s = MsgStream.init(16)
    s.pack_array(2)
    s.pack_type(0)
    s.pack_type(1)
    var parser = initRpcParser()
    expect(ValueError):
      discard parser.feed(s.data)
