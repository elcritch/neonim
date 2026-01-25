import std/[streams, tables, macros, strutils]
import msgpack4nim

type
  RpcMessageKind* = enum
    rmRequest = 0
    rmResponse = 1
    rmNotification = 2

  RpcMessage* = object
    kind*: RpcMessageKind
    msgid*: uint64
    methodName*: string
    params*: RpcParamsBuffer
    error*: RpcParamsBuffer
    result*: RpcParamsBuffer

  RpcParser* = object
    buffer: string

  RpcSession* = object
    parser*: RpcParser
    nextId*: uint64
    pending: Table[uint64, string]

  RpcContext* = object
    msgid*: uint64

  RpcParamsBuffer* = object
    buf*: MsgStream

  RpcProc* = proc(params: RpcParamsBuffer, context: RpcContext): RpcParamsBuffer {.gcsafe, nimcall.}

  RpcRouter* = ref object
    procs*: Table[string, RpcProc]

proc initRpcParser*(): RpcParser =
  RpcParser(buffer: "")

proc initRpcSession*(): RpcSession =
  RpcSession(parser: initRpcParser(), nextId: 1, pending: initTable[uint64, string]())

proc newRpcRouter*(): RpcRouter =
  new(result)
  result.procs = initTable[string, RpcProc]()

proc register*(router: RpcRouter, methodName: string, call: RpcProc) =
  router.procs[methodName] = call

proc hasMethod*(router: RpcRouter, methodName: string): bool =
  router.procs.hasKey(methodName)

proc newRequest*(msgid: uint64, methodName: string, params: RpcParamsBuffer): RpcMessage =
  RpcMessage(kind: rmRequest, msgid: msgid, methodName: methodName, params: params)

proc newResponse*(msgid: uint64, error, res: RpcParamsBuffer): RpcMessage =
  RpcMessage(kind: rmResponse, msgid: msgid, error: error, result: res)

proc newNotification*(methodName: string, params: RpcParamsBuffer): RpcMessage =
  RpcMessage(kind: rmNotification, methodName: methodName, params: params)

proc rpcPack*[T](val: T): RpcParamsBuffer =
  var s = MsgStream.init()
  s.pack(val)
  s.setPosition(s.data.len)
  RpcParamsBuffer(buf: s)

proc rpcPackNil*(): RpcParamsBuffer =
  var s = MsgStream.init()
  var p: pointer = nil
  s.pack(p)
  s.setPosition(s.data.len)
  RpcParamsBuffer(buf: s)

proc rpcUnpack*[T](buf: RpcParamsBuffer, val: var T) =
  try:
    buf.buf.setPosition(0)
    buf.buf.unpack(val)
  except ObjectConversionDefect as err:
    raise newException(ValueError, "msgpack rpc: invalid param: " & err.msg)

proc rpcUnpack*[T](buf: RpcParamsBuffer): T =
  rpcUnpack(buf, result)

proc isNilValue*(buf: RpcParamsBuffer): bool =
  result = buf.buf.data.len == 1 and buf.buf.data[0] == pack_value_nil

macro rpcPackParams*(args: varargs[untyped]): untyped =
  let argCount = newLit(args.len)
  let sIdent = genSym(nskVar, "rpcParamsBuf")
  var body = newStmtList()
  body.add quote do:
    var `sIdent` = MsgStream.init()
    `sIdent`.pack_array(`argCount`)
  for arg in args:
    body.add quote do:
      `sIdent`.pack(`arg`)
  body.add quote do:
    `sIdent`.setPosition(`sIdent`.data.len)
    RpcParamsBuffer(buf: `sIdent`)
  result = newTree(nnkBlockStmt, newEmptyNode(), body)

proc initRpcParamsBuffer*(data: string): RpcParamsBuffer =
  var s = MsgStream.init(data)
  s.setPosition(s.data.len)
  RpcParamsBuffer(buf: s)

proc pack_type*[ByteStream](s: ByteStream, x: RpcParamsBuffer) =
  let size =
    if x.buf.getPosition() > 0: x.buf.getPosition()
    else: x.buf.data.len
  if size > 0:
    s.write(x.buf.data[0 ..< size])

proc unpack_type*[ByteStream](s: ByteStream, x: var RpcParamsBuffer) =
  let data = s.readStrRemaining()
  x = initRpcParamsBuffer(data)

proc encodeMessage*(msg: RpcMessage): string =
  var s = MsgStream.init(128)
  case msg.kind
  of rmRequest:
    s.pack_array(4)
    s.pack(ord(rmRequest))
    s.pack(msg.msgid)
    s.pack(msg.methodName)
    s.pack(msg.params)
  of rmResponse:
    s.pack_array(4)
    s.pack(ord(rmResponse))
    s.pack(msg.msgid)
    s.pack(msg.error)
    s.pack(msg.result)
  of rmNotification:
    s.pack_array(3)
    s.pack(ord(rmNotification))
    s.pack(msg.methodName)
    s.pack(msg.params)
  result = s.data

proc startRequest*(session: var RpcSession, methodName: string, params: RpcParamsBuffer): tuple[id: uint64, data: string] =
  let id = session.nextId
  session.nextId.inc
  session.pending[id] = methodName
  result = (id, encodeMessage(newRequest(id, methodName, params)))

proc sendNotification*(methodName: string, params: RpcParamsBuffer): string =
  encodeMessage(newNotification(methodName, params))

proc sendResponse*(msgid: uint64, error, res: RpcParamsBuffer): string =
  encodeMessage(newResponse(msgid, error, res))

proc callMethod*(router: RpcRouter, msg: RpcMessage): RpcMessage =
  if msg.kind != rmRequest:
    raise newException(ValueError, "msgpack rpc: only requests can be dispatched")
  let rpcProc = router.procs.getOrDefault(msg.methodName)
  if rpcProc.isNil:
    return newResponse(msg.msgid, rpcPack("method not found"), rpcPackNil())
  let ctx = RpcContext(msgid: msg.msgid)
  try:
    let res = rpcProc(msg.params, ctx)
    result = newResponse(msg.msgid, rpcPackNil(), res)
  except CatchableError as err:
    result = newResponse(msg.msgid, rpcPack(err.msg), rpcPackNil())

proc pendingRequests*(session: RpcSession): seq[uint64] =
  for key in session.pending.keys:
    result.add key

proc completeRequest*(session: var RpcSession, msgid: uint64): bool =
  result = session.pending.hasKey(msgid)
  if result:
    session.pending.del(msgid)

proc readMethod(s: MsgStream): string =
  let c = s.peekChar
  if c >= chr(0xa0) and c <= chr(0xbf) or c in {chr(0xd9), chr(0xda), chr(0xdb)}:
    let len = s.unpack_string()
    if len < 0:
      raise newException(ValueError, "msgpack rpc: missing method")
    result = s.readExactStr(len)
  elif c in {chr(0xc4), chr(0xc5), chr(0xc6)}:
    let len = s.unpack_bin()
    result = s.readExactStr(len)
  else:
    raise newException(ValueError, "msgpack rpc: method must be string or bin")

proc readMsgId(s: MsgStream): uint64 =
  if s.is_uint():
    var u: uint64
    s.unpack(u)
    return u
  if s.is_int():
    var i: int64
    s.unpack(i)
    if i < 0:
      raise newException(ValueError, "msgpack rpc: msgid must be >= 0")
    return uint64(i)
  raise newException(ValueError, "msgpack rpc: msgid must be an integer")

proc readRawBuffer(s: MsgStream): RpcParamsBuffer =
  let start = s.getPosition()
  s.skip_msg()
  let stop = s.getPosition()
  result = initRpcParamsBuffer(s.data[start ..< stop])

proc decodeMessage*(s: MsgStream): RpcMessage =
  let msgLen = s.unpack_array()
  if msgLen notin [3, 4]:
    raise newException(ValueError, "msgpack rpc: message length must be 3 or 4")
  var kindValue: int64
  if s.is_uint():
    var u: uint64
    s.unpack(u)
    kindValue = int64(u)
  elif s.is_int():
    s.unpack(kindValue)
  else:
    raise newException(ValueError, "msgpack rpc: message type must be integer")

  case kindValue
  of 0:
    if msgLen != 4:
      raise newException(ValueError, "msgpack rpc: request length must be 4")
    let msgid = readMsgId(s)
    let methodName = readMethod(s)
    let params = readRawBuffer(s)
    result = newRequest(msgid, methodName, params)
  of 1:
    if msgLen != 4:
      raise newException(ValueError, "msgpack rpc: response length must be 4")
    let msgid = readMsgId(s)
    let error = readRawBuffer(s)
    let res = readRawBuffer(s)
    result = newResponse(msgid, error, res)
  of 2:
    if msgLen != 3:
      raise newException(ValueError, "msgpack rpc: notification length must be 3")
    let methodName = readMethod(s)
    let params = readRawBuffer(s)
    result = newNotification(methodName, params)
  else:
    raise newException(ValueError, "msgpack rpc: unknown message type")

proc decodeSingle*(data: string): RpcMessage =
  var s = MsgStream.init(data)
  result = decodeMessage(s)
  if s.getPosition() != data.len:
    raise newException(ValueError, "msgpack rpc: trailing bytes in message")

proc makeProcName(s: string): string =
  result = ""
  for c in s:
    if c.isAlphaNumeric:
      result.add c

proc hasReturnType(params: NimNode): bool =
  if params != nil and params.len > 0 and params[0] != nil and
     params[0].kind != nnkEmpty:
    result = true

iterator paramsIter(params: NimNode): tuple[name, ntype: NimNode] =
  for i in 1 ..< params.len:
    let arg = params[i]
    let argType = arg[^2]
    for j in 0 ..< arg.len-2:
      yield (arg[j], argType)

proc isRpcSessionType(paramType: NimNode): bool {.compileTime.} =
  case paramType.kind
  of nnkVarTy:
    result = paramType[0].repr == "RpcSession"
  of nnkIdent, nnkSym:
    result = paramType.repr == "RpcSession"
  else:
    result = false

proc filterPragmas(pragmas: NimNode, remove: seq[string]): NimNode {.compileTime.} =
  if pragmas.isNil or pragmas.kind == nnkEmpty:
    return pragmas
  var outPragmas = newNimNode(nnkPragma)
  for child in pragmas:
    if child.kind in {nnkIdent, nnkSym} and child.repr in remove:
      continue
    outPragmas.add child
  if outPragmas.len == 0:
    result = newEmptyNode()
  else:
    result = outPragmas

proc mkParamsVars(paramsIdent, paramsType, params: NimNode): NimNode =
  ## Create local variables for each parameter in the actual RPC call proc.
  if params.isNil:
    return
  result = newStmtList()
  var varList = newSeq[NimNode]()
  for paramid, paramType in paramsIter(params):
    let localName = ident(paramid.strVal)
    varList.add quote do:
      var `localName`: `paramType` = `paramsIdent`.`localName`
  result.add varList

proc mkParamsType*(paramsIdent, paramsType, params: NimNode): NimNode =
  ## Create a type that represents the arguments for this rpc call.
  if params.isNil:
    return
  var typObj = quote do:
    type
      `paramsType` = object
  var recList = newNimNode(nnkRecList)
  for paramIdent, paramType in paramsIter(params):
    recList.add newIdentDefs(postfix(paramIdent, "*"), paramType)
  typObj[0][2][2] = recList
  result = typObj

proc isVoidType(params: NimNode): bool {.compileTime.} =
  if params.isNil or params.len == 0 or params[0].isNil:
    return false
  let ret = params[0]
  result = ret.kind in {nnkIdent, nnkSym} and ret.repr == "void"

proc paramsCount(params: NimNode): int {.compileTime.} =
  var count = 0
  for _ in paramsIter(params):
    inc(count)
  result = count

proc mkParamUnpack(paramsType, params, paramTotal: NimNode): NimNode =
  let sIdent = genSym(nskParam, "stream")
  let valIdent = genSym(nskParam, "val")
  var body = newStmtList()
  body.add quote do:
    let arrLen = `sIdent`.unpack_array()
    if arrLen != `paramTotal`:
      raise conversionError("params")
  for paramid, _ in paramsIter(params):
    let field = newDotExpr(valIdent, ident(paramid.strVal))
    body.add quote do:
      `sIdent`.unpack(`field`)
  result = quote do:
    proc unpack_type(`sIdent`: Stream, `valIdent`: var `paramsType`) =
      `body`

macro rpcImpl*(p: untyped): untyped =
  ## Define a msgpack-rpc procedure for Neovim.
  let
    path = $p[0]
    params = p[3]
    body = p[6]

  result = newStmtList()

  let
    pathStr = $path
    procNameStr = pathStr.makeProcName()
    procName = ident(procNameStr & "Func")
    rpcMethod = ident(procNameStr)
    ctxName = ident("context")
    paramsIdent = genSym(nskParam, "rpcArgs")
    paramsObj = genSym(nskVar, "rpcArgsObj")
    paramTypeName = ident("RpcType_" & procNameStr)
    paramsVar = ident("params")

  let
    paramSetups = mkParamsVars(paramsIdent, paramTypeName, params)
    paramTypes = mkParamsType(paramsIdent, paramTypeName, params)
    procBody = if body.kind == nnkStmtList: body else: body.body
    paramTotal = newLit(paramsCount(params))
    paramUnpack = mkParamUnpack(paramTypeName, params, paramTotal)
    voidRet = isVoidType(params)

  if not params.hasReturnType:
    error("msgpack rpc: must provide return type")
  let ReturnType = params[0]

  result.add quote do:
    `paramTypes`
    `paramUnpack`

    proc `procName`(`paramsIdent`: `paramTypeName`,
                    `ctxName`: RpcContext
                    ): `ReturnType` =
      {.cast(gcsafe).}:
        `paramSetups`
        `procBody`

  if voidRet:
    result.add quote do:
      proc `rpcMethod`(`paramsVar`: RpcParamsBuffer, context: RpcContext): RpcParamsBuffer {.gcsafe, nimcall.} =
        var `paramsObj`: `paramTypeName`
        `paramsVar`.buf.setPosition(0)
        `paramsVar`.buf.unpack(`paramsObj`)
        discard `procName`(`paramsObj`, context)
        result = rpcPackNil()
  else:
    result.add quote do:
      proc `rpcMethod`(`paramsVar`: RpcParamsBuffer, context: RpcContext): RpcParamsBuffer {.gcsafe, nimcall.} =
        var `paramsObj`: `paramTypeName`
        `paramsVar`.buf.setPosition(0)
        `paramsVar`.buf.unpack(`paramsObj`)
        let res = `procName`(`paramsObj`, context)
        result = rpcPack(res)

  result.add quote do:
    register(router, `path`, `rpcMethod`)

template rpc*(p: untyped): untyped =
  rpcImpl(p)

macro rpcClientImpl*(p: untyped, notify: static[bool]): untyped =
  let
    path = $p[0]
    params = p[3]
    pragmas = p[4]

  if not params.hasReturnType:
    error("msgpack rpc: must provide return type")
  var argSyms = newSeq[NimNode]()
  var sessionSym: NimNode = nil
  var idx = 0
  for paramid, paramType in paramsIter(params):
    if not notify and idx == 0 and isRpcSessionType(paramType):
      sessionSym = ident(paramid.strVal)
    else:
      argSyms.add ident(paramid.strVal)
    inc(idx)

  if not notify and sessionSym.isNil:
    error("msgpack rpc: request procs must take `session: var RpcSession` as the first parameter")

  let paramsCall = newCall(ident("rpcPackParams"), argSyms)
  var body = newStmtList()
  if notify:
    body.add quote do:
      result = sendNotification(`path`, `paramsCall`)
  else:
    body.add quote do:
      result = startRequest(`sessionSym`, `path`, `paramsCall`)

  let filteredPragmas = filterPragmas(pragmas, @["rpcRequest", "rpcNotify"])
  result = newTree(nnkProcDef,
    p[0],
    newEmptyNode(),
    newEmptyNode(),
    params,
    filteredPragmas,
    newEmptyNode(),
    body
  )

template rpcRequest*(p: untyped): untyped =
  rpcClientImpl(p, false)

template rpcClient*(p: untyped): untyped =
  rpcClientImpl(p, false)

template rpcNotify*(p: untyped): untyped =
  rpcClientImpl(p, true)

proc feed*(parser: var RpcParser, data: string): seq[RpcMessage] =
  if data.len > 0:
    parser.buffer.add(data)
  while parser.buffer.len > 0:
    var s = MsgStream.init(parser.buffer)
    let msg =
      try:
        decodeMessage(s)
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
    result.add msg
