import std/[streams, tables]
import msgpack4nim
import msgpack4nim/msgpack2any

type
  RpcMessageKind* = enum
    rmRequest = 0
    rmResponse = 1
    rmNotification = 2

  RpcMessage* = object
    kind*: RpcMessageKind
    msgid*: uint64
    methodName*: string
    params*: seq[MsgAny]
    error*: MsgAny
    result*: MsgAny

  RpcParser* = object
    buffer: string

  RpcSession* = object
    parser*: RpcParser
    nextId*: uint64
    pending: Table[uint64, string]

proc initRpcParser*(): RpcParser =
  RpcParser(buffer: "")

proc initRpcSession*(): RpcSession =
  RpcSession(parser: initRpcParser(), nextId: 1, pending: initTable[uint64, string]())

proc newRequest*(msgid: uint64, methodName: string, params: seq[MsgAny]): RpcMessage =
  RpcMessage(kind: rmRequest, msgid: msgid, methodName: methodName, params: params)

proc newResponse*(msgid: uint64, error, res: MsgAny): RpcMessage =
  RpcMessage(kind: rmResponse, msgid: msgid, error: error, result: res)

proc newNotification*(methodName: string, params: seq[MsgAny]): RpcMessage =
  RpcMessage(kind: rmNotification, methodName: methodName, params: params)

proc encodeMessage*(msg: RpcMessage): string =
  var s = MsgStream.init(128)
  case msg.kind
  of rmRequest:
    s.pack_array(4)
    s.pack_type(ord(rmRequest))
    s.pack_type(msg.msgid)
    s.pack_type(msg.methodName)
    s.pack_array(msg.params.len)
    for param in msg.params:
      fromAny(s, param)
  of rmResponse:
    s.pack_array(4)
    s.pack_type(ord(rmResponse))
    s.pack_type(msg.msgid)
    fromAny(s, msg.error)
    fromAny(s, msg.result)
  of rmNotification:
    s.pack_array(3)
    s.pack_type(ord(rmNotification))
    s.pack_type(msg.methodName)
    s.pack_array(msg.params.len)
    for param in msg.params:
      fromAny(s, param)
  result = s.data

proc startRequest*(session: var RpcSession, methodName: string, params: seq[MsgAny]): tuple[id: uint64, data: string] =
  let id = session.nextId
  session.nextId.inc
  session.pending[id] = methodName
  result = (id, encodeMessage(newRequest(id, methodName, params)))

proc sendNotification*(methodName: string, params: seq[MsgAny]): string =
  encodeMessage(newNotification(methodName, params))

proc sendResponse*(msgid: uint64, error, res: MsgAny): string =
  encodeMessage(newResponse(msgid, error, res))

proc pendingRequests*(session: RpcSession): seq[uint64] =
  for key in session.pending.keys:
    result.add key

proc completeRequest*(session: var RpcSession, msgid: uint64): bool =
  result = session.pending.hasKey(msgid)
  if result:
    session.pending.del(msgid)

proc requireArray(node: MsgAny): seq[MsgAny] =
  if node.isNil or node.kind != msgArray:
    raise newException(ValueError, "msgpack rpc: expected array")
  result = node.arrayVal

proc requireMethod(node: MsgAny): string =
  if node.isNil:
    raise newException(ValueError, "msgpack rpc: missing method")
  case node.kind
  of msgString:
    result = node.stringVal
  of msgBin:
    result = node.binData
  else:
    raise newException(ValueError, "msgpack rpc: method must be string or bin")

proc requireMsgId(node: MsgAny): uint64 =
  if node.isNil:
    raise newException(ValueError, "msgpack rpc: missing msgid")
  case node.kind
  of msgUint:
    result = node.uintVal
  of msgInt:
    if node.intVal < 0:
      raise newException(ValueError, "msgpack rpc: msgid must be >= 0")
    result = uint64(node.intVal)
  else:
    raise newException(ValueError, "msgpack rpc: msgid must be an integer")

proc decodeMessage*(node: MsgAny): RpcMessage =
  let items = requireArray(node)
  if items.len notin [3, 4]:
    raise newException(ValueError, "msgpack rpc: message length must be 3 or 4")
  let kindNode = items[0]
  var kindValue: int64
  case kindNode.kind
  of msgInt:
    kindValue = kindNode.intVal
  of msgUint:
    kindValue = int64(kindNode.uintVal)
  else:
    raise newException(ValueError, "msgpack rpc: message type must be integer")

  case kindValue
  of 0:
    if items.len != 4:
      raise newException(ValueError, "msgpack rpc: request length must be 4")
    result = newRequest(requireMsgId(items[1]), requireMethod(items[2]), requireArray(items[3]))
  of 1:
    if items.len != 4:
      raise newException(ValueError, "msgpack rpc: response length must be 4")
    result = newResponse(requireMsgId(items[1]), items[2], items[3])
  of 2:
    if items.len != 3:
      raise newException(ValueError, "msgpack rpc: notification length must be 3")
    result = newNotification(requireMethod(items[1]), requireArray(items[2]))
  else:
    raise newException(ValueError, "msgpack rpc: unknown message type")

proc feed*(parser: var RpcParser, data: string): seq[RpcMessage] =
  if data.len > 0:
    parser.buffer.add(data)
  while parser.buffer.len > 0:
    var s = MsgStream.init(parser.buffer)
    let node =
      try:
        s.toAny()
      except IOError:
        break
      except ObjectConversionDefect as err:
        raise newException(ValueError, "msgpack rpc: invalid msgpack: " & err.msg)
    let consumed = s.getPosition()
    if consumed <= 0:
      break
    if consumed >= parser.buffer.len:
      parser.buffer.setLen(0)
    else:
      parser.buffer = parser.buffer[consumed .. ^1]
    result.add decodeMessage(node)
