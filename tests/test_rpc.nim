import std/unittest
import neovim_figs/rpc
import msgpack4nim
import msgpack4nim/msgpack2any

suite "neovim msgpack rpc":
  test "request encode/decode":
    var session = initRpcSession()
    let params: seq[MsgAny] = @[]
    let (id, data) = startRequest(session, "vim_get_api_info", params)
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
    check msg.params.len == 0

  test "response encode/decode":
    let data = sendResponse(3, anyNull(), anyString("ok"))
    var parser = initRpcParser()
    let messages = parser.feed(data)
    check messages.len == 1
    let msg = messages[0]
    check msg.kind == rmResponse
    check msg.msgid == 3
    check msg.error.kind == msgNull
    check msg.result.kind == msgString
    check msg.result.stringVal == "ok"

  test "notification encode/decode":
    let params = @[anyInt(1), anyInt(2)]
    let data = sendNotification("redraw", params)
    var parser = initRpcParser()
    let messages = parser.feed(data)
    check messages.len == 1
    let msg = messages[0]
    check msg.kind == rmNotification
    check msg.methodName == "redraw"
    check msg.params.len == 2
    check msg.params[0].intVal == 1
    check msg.params[1].intVal == 2

  test "incremental parse":
    let data = sendNotification("incremental", @[anyString("ok")])
    let mid = data.len div 2
    var parser = initRpcParser()
    check parser.feed(data[0 ..< mid]).len == 0
    let messages = parser.feed(data[mid .. ^1])
    check messages.len == 1
    check messages[0].methodName == "incremental"

  test "invalid frame errors":
    var s = MsgStream.init(16)
    s.pack_array(2)
    s.pack_type(0)
    s.pack_type(1)
    var parser = initRpcParser()
    expect(ValueError):
      discard parser.feed(s.data)
