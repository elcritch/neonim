import std/[os, osproc, streams, tables, times]
when not defined(windows):
  import std/posix
import msgpack4nim

import ./rpc

type
  NeovimError* = object of CatchableError

  NeovimMetadata* = object
    channelId*: int64
    apiLevel*: int64
    apiCompatible*: int64
    uiOptions*: seq[string]

  NeovimNotificationHandler* =
    proc(methodName: string, params: RpcParamsBuffer) {.gcsafe, closure.}

  NeovimClient* = ref object
    process: Process
    inStream: Stream
    when not defined(windows):
      outFd: FileHandle
      errFd: FileHandle

    parser: RpcParser
    session: RpcSession
    responses: Table[uint64, RpcMessage]
    notifications: seq[RpcMessage]

    onNotification*: NeovimNotificationHandler

proc unpackInt64(s: MsgStream): int64 =
  if s.is_uint():
    var u: uint64
    s.unpack(u)
    return int64(u)
  if s.is_int():
    var i: int64
    s.unpack(i)
    return i
  raise newException(NeovimError, "expected integer")

proc unpackStringOrBin(s: MsgStream): string =
  if s.is_string():
    let len = s.unpack_string()
    if len < 0:
      raise newException(NeovimError, "expected string")
    return s.readExactStr(len)
  if s.is_bin():
    let len = s.unpack_bin()
    return s.readExactStr(len)
  raise newException(NeovimError, "expected string/bin")

proc parseMetadata*(buf: RpcParamsBuffer): NeovimMetadata =
  var s = MsgStream.init(buf.buf.data)
  s.setPosition(0)
  let outerLen = s.unpack_array()
  if outerLen != 2:
    raise
      newException(NeovimError, "vim_get_api_info result must be [channel, metadata]")

  result.channelId = unpackInt64(s)
  if not s.is_map():
    raise newException(NeovimError, "vim_get_api_info metadata must be map")
  let mapLen = s.unpack_map()
  for _ in 0 ..< mapLen:
    let key = unpackStringOrBin(s)
    case key
    of "version":
      if not s.is_map():
        raise newException(NeovimError, "metadata.version must be map")
      let verLen = s.unpack_map()
      for _ in 0 ..< verLen:
        let vkey = unpackStringOrBin(s)
        case vkey
        of "api_level":
          result.apiLevel = unpackInt64(s)
        of "api_compatible":
          result.apiCompatible = unpackInt64(s)
        else:
          s.skip_msg()
    of "ui_options":
      if not s.is_array():
        s.skip_msg()
      else:
        let optLen = s.unpack_array()
        for _ in 0 ..< optLen:
          result.uiOptions.add unpackStringOrBin(s)
    else:
      s.skip_msg()

when not defined(windows):
  proc setNonBlocking(fd: FileHandle) =
    var flags = fcntl(fd, F_GETFL, 0)
    if flags < 0:
      raise newException(NeovimError, "fcntl(F_GETFL) failed")
    flags = flags or O_NONBLOCK
    if fcntl(fd, F_SETFL, flags) < 0:
      raise newException(NeovimError, "fcntl(F_SETFL) failed")

proc start*(client: NeovimClient, nvimCmd = "nvim", args: seq[string] = @[]) =
  if client.process != nil:
    raise newException(NeovimError, "client already started")

  let fullArgs = @["--embed"] & args
  client.process = startProcess(nvimCmd, args = fullArgs, options = {poUsePath})
  client.inStream = client.process.inputStream()
  when not defined(windows):
    client.outFd = client.process.outputHandle()
    client.errFd = client.process.errorHandle()
    setNonBlocking(client.outFd)
    setNonBlocking(client.errFd)

  client.parser = initRpcParser()
  client.session = initRpcSession()
  client.responses = initTable[uint64, RpcMessage]()
  client.notifications = @[]

proc poll*(client: NeovimClient)

proc stop*(client: NeovimClient) =
  if client.isNil or client.process.isNil:
    return
  try:
    client.process.terminate()
  except CatchableError:
    discard
  try:
    discard client.process.waitForExit(200)
  except CatchableError:
    discard
  try:
    client.process.close()
  except CatchableError:
    discard
  client.process = nil

proc isRunning*(client: NeovimClient): bool =
  if client.isNil or client.process.isNil:
    return false
  try:
    return client.process.running()
  except CatchableError:
    return false

proc waitForExit*(client: NeovimClient, timeout = 2.0): bool =
  let startTime = epochTime()
  while true:
    if not client.isRunning():
      return true
    if epochTime() - startTime > timeout:
      return false
    client.poll()
    sleep(1)

proc newNeovimClient*(): NeovimClient =
  new(result)

proc takeNotifications*(client: NeovimClient): seq[RpcMessage] =
  result = client.notifications
  client.notifications.setLen(0)

proc sendRaw(client: NeovimClient, data: string) =
  client.inStream.write(data)
  client.inStream.flush()

proc request*(
    client: NeovimClient, methodName: string, params: RpcParamsBuffer
): uint64 =
  var session = client.session
  let (id, data) = startRequest(session, methodName, params)
  client.session = session
  client.sendRaw(data)
  result = id

proc notify*(client: NeovimClient, methodName: string, params: RpcParamsBuffer) =
  client.sendRaw(sendNotification(methodName, params))

when not defined(windows):
  proc readAvailable(fd: FileHandle): string =
    while true:
      var buf = newString(16 * 1024)
      let n = posix.read(fd, addr buf[0], buf.len)
      if n > 0:
        buf.setLen(n)
        result.add(buf)
        continue
      if n == 0:
        return
      let e = errno
      if e == EAGAIN or e == EWOULDBLOCK:
        return
      raise newException(NeovimError, "read() failed: errno=" & $e)

proc poll*(client: NeovimClient) =
  when defined(windows):
    discard
  else:
    let data = readAvailable(client.outFd)
    if data.len > 0:
      for msg in client.parser.feed(data):
        case msg.kind
        of rmResponse:
          client.responses[msg.msgid] = msg
          var session = client.session
          discard session.completeRequest(msg.msgid)
          client.session = session
        of rmNotification:
          client.notifications.add msg
          if client.onNotification != nil:
            client.onNotification(msg.methodName, msg.params)
        of rmRequest:
          discard
    discard readAvailable(client.errFd) # drain to avoid blocking the child

proc waitResponse*(client: NeovimClient, msgid: uint64, timeout = 2.0): RpcMessage =
  let startTime = epochTime()
  while true:
    if client.process != nil:
      try:
        if not client.process.running():
          raise newException(
            NeovimError, "nvim exited while waiting for response: " & $msgid
          )
      except CatchableError:
        discard
    client.poll()
    if client.responses.hasKey(msgid):
      result = client.responses[msgid]
      client.responses.del(msgid)
      return
    if epochTime() - startTime > timeout:
      raise newException(NeovimError, "timeout waiting for response: " & $msgid)
    sleep(1)

proc callAndWait*(
    client: NeovimClient, methodName: string, params: RpcParamsBuffer, timeout = 2.0
): RpcMessage =
  let id = client.request(methodName, params)
  result = client.waitResponse(id, timeout)

proc discoverMetadata*(client: NeovimClient): NeovimMetadata =
  let resp = client.callAndWait("vim_get_api_info", rpcPackParams(), timeout = 10.0)
  if not resp.error.isNilValue:
    raise newException(
      NeovimError, "vim_get_api_info failed: " & rpcUnpack[string](resp.error)
    )
  result = parseMetadata(resp.result)
