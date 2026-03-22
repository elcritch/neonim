import std/[os, osproc, streams, strutils, tables, times, net]
import chronicles
when not defined(windows):
  import std/nativesockets
when not defined(windows):
  import std/posix
import msgpack4nim

import ./rpc

type
  NeovimTransportKind = enum
    ntkNone
    ntkProcess
    ntkSocket

  NeovimServerAddressKind = enum
    nsakTcp
    nsakUnix

  NeovimServerAddress = object
    case kind: NeovimServerAddressKind
    of nsakTcp:
      host: string
      port: Port
    of nsakUnix:
      path: string

  NeovimError* = object of CatchableError

  NeovimMetadata* = object
    channelId*: int64
    apiLevel*: int64
    apiCompatible*: int64
    uiOptions*: seq[string]

  NeovimNotificationHandler* =
    proc(methodName: string, params: RpcParamsBuffer) {.gcsafe, closure.}

  NeovimClient* = ref object
    transport: NeovimTransportKind
    process: Process
    inStream: Stream
    rpcSocket: Socket
    when not defined(windows):
      outFd: FileHandle
      errFd: FileHandle
      socketDisconnected: bool

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
  if not s.is_array():
    raise newException(NeovimError, "vim_get_api_info result must be array")
  let outerLen = s.unpack_array()
  if outerLen != 2:
    raise
      newException(NeovimError, "vim_get_api_info result must be [channel, metadata]")

  result.channelId = unpackInt64(s)
  if not s.is_map():
    raise newException(NeovimError, "vim_get_api_info metadata must be map")
  let mapLen = s.unpack_map()
  for _ in 0 ..< mapLen:
    if not (s.is_string() or s.is_bin()):
      s.skip_msg() # key
      s.skip_msg() # value
      continue
    let key = unpackStringOrBin(s)
    case key
    of "version":
      if not s.is_map():
        s.skip_msg()
        continue
      let verLen = s.unpack_map()
      for _ in 0 ..< verLen:
        if not (s.is_string() or s.is_bin()):
          s.skip_msg()
          s.skip_msg()
          continue
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
          if s.is_string() or s.is_bin():
            result.uiOptions.add unpackStringOrBin(s)
          else:
            s.skip_msg()
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

proc extractServerAddress(args: seq[string]): string =
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--":
      break
    if arg == "--server":
      if i + 1 >= args.len:
        raise newException(NeovimError, "--server requires an address")
      return args[i + 1]
    if arg.startsWith("--server="):
      return arg["--server=".len .. ^1]
    inc i

proc parseTcpServerAddress(serverAddress: string): tuple[host: string, port: Port] =
  var value = serverAddress.strip()
  if value.startsWith("tcp://"):
    value = value[6 .. ^1]
  if value.len == 0:
    raise newException(NeovimError, "invalid --server address: empty value")

  var host = ""
  var portText = ""
  if value[0] == '[':
    let endBracket = value.find(']')
    if endBracket <= 0 or endBracket + 2 > value.high or value[endBracket + 1] != ':':
      raise newException(NeovimError, "invalid --server address, expected [host]:port")
    host = value[1 ..< endBracket]
    portText = value[endBracket + 2 .. ^1]
  else:
    let splitAt = value.rfind(':')
    if splitAt <= 0 or splitAt >= value.high:
      raise newException(NeovimError, "invalid --server address, expected host:port")
    host = value[0 ..< splitAt]
    portText = value[splitAt + 1 .. ^1]

  if host.len == 0 or portText.len == 0:
    raise newException(NeovimError, "invalid --server address, expected host:port")
  try:
    let parsedPort = parseInt(portText)
    if parsedPort <= 0 or parsedPort > 65535:
      raise
        newException(NeovimError, "invalid --server port, must be in range 1..65535")
    result = (host, Port(parsedPort))
  except ValueError:
    raise newException(NeovimError, "invalid --server port: " & portText)

proc parseServerAddress(serverAddress: string): NeovimServerAddress =
  var value = serverAddress.strip()
  if value.len == 0:
    raise newException(NeovimError, "invalid --server address: empty value")

  if value.startsWith("unix://"):
    let path = value["unix://".len .. ^1]
    if path.len == 0:
      raise newException(NeovimError, "invalid --server unix path: empty value")
    when defined(windows):
      raise newException(
        NeovimError, "unix socket addresses are not supported on this platform"
      )
    else:
      return NeovimServerAddress(kind: nsakUnix, path: path)

  if value.startsWith("tcp://") or value.contains(":"):
    let (host, port) = parseTcpServerAddress(value)
    return NeovimServerAddress(kind: nsakTcp, host: host, port: port)

  when defined(windows):
    raise newException(NeovimError, "invalid --server address, expected host:port")
  else:
    return NeovimServerAddress(kind: nsakUnix, path: value)

proc initRpcState(client: NeovimClient) =
  client.parser = initRpcParser()
  client.session = initRpcSession()
  client.responses = initTable[uint64, RpcMessage]()
  client.notifications = @[]
  when not defined(windows):
    client.socketDisconnected = false

proc start*(client: NeovimClient, nvimCmd = "nvim", args: seq[string] = @[], cwd = "") =
  if client.transport != ntkNone:
    raise newException(NeovimError, "client already started")

  client.initRpcState()
  let serverAddress = extractServerAddress(args)
  if serverAddress.len > 0:
    let server = parseServerAddress(serverAddress)
    case server.kind
    of nsakTcp:
      client.rpcSocket = dial(server.host, server.port, buffered = false)
    of nsakUnix:
      when defined(windows):
        raise newException(
          NeovimError, "unix socket addresses are not supported on this platform"
        )
      else:
        let rawSocket = createNativeSocket(AF_UNIX.cint, SOCK_STREAM.cint, 0)
        if rawSocket == osInvalidSocket:
          raiseOSError(osLastError())
        client.rpcSocket = newSocket(
          rawSocket,
          domain = AF_UNIX,
          sockType = SOCK_STREAM,
          protocol = IPPROTO_TCP,
          buffered = false,
        )
        client.rpcSocket.connectUnix(server.path)
    when not defined(windows):
      setNonBlocking(cast[FileHandle](client.rpcSocket.getFd()))
    client.transport = ntkSocket
    return

  let fullArgs = @["--embed"] & args
  if cwd.len > 0:
    client.process =
      startProcess(nvimCmd, args = fullArgs, options = {poUsePath}, workingDir = cwd)
  else:
    client.process = startProcess(nvimCmd, args = fullArgs, options = {poUsePath})
  client.inStream = client.process.inputStream()
  when not defined(windows):
    client.outFd = client.process.outputHandle()
    client.errFd = client.process.errorHandle()
    setNonBlocking(client.outFd)
    setNonBlocking(client.errFd)
  client.transport = ntkProcess

proc poll*(client: NeovimClient)

proc stop*(client: NeovimClient) =
  if client.isNil:
    return
  if client.transport == ntkProcess and not client.process.isNil:
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
  if client.transport == ntkSocket and not client.rpcSocket.isNil:
    try:
      client.rpcSocket.close()
    except CatchableError:
      discard
  client.process = nil
  client.inStream = nil
  client.rpcSocket = nil
  client.transport = ntkNone
  when not defined(windows):
    client.socketDisconnected = true

proc isRunning*(client: NeovimClient): bool =
  if client.isNil:
    return false
  case client.transport
  of ntkNone:
    return false
  of ntkProcess:
    if client.process.isNil:
      return false
    try:
      return client.process.running()
    except CatchableError:
      return false
  of ntkSocket:
    when defined(windows):
      return not client.rpcSocket.isNil
    else:
      return (not client.rpcSocket.isNil) and (not client.socketDisconnected)

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

proc dispatchNotification*(client: NeovimClient, msg: RpcMessage) =
  client.notifications.add msg
  if client.onNotification == nil:
    return
  try:
    client.onNotification(msg.methodName, msg.params)
  except CatchableError as err:
    warn "nvim notification handler failed", rpcMethod = msg.methodName, error = err.msg

proc sendRaw(client: NeovimClient, data: string) =
  case client.transport
  of ntkProcess:
    client.inStream.write(data)
    client.inStream.flush()
  of ntkSocket:
    if client.rpcSocket.isNil:
      raise newException(NeovimError, "nvim server socket is not connected")
    client.rpcSocket.send(data)
  of ntkNone:
    raise newException(NeovimError, "neovim client is not started")

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

  proc readAvailableSocket(socket: Socket, disconnected: var bool): string =
    while true:
      var buf = newString(16 * 1024)
      let n = socket.recv(addr buf[0], buf.len)
      if n > 0:
        buf.setLen(n)
        result.add(buf)
        continue
      if n == 0:
        disconnected = true
        return
      let e = getSocketError(socket).int32
      if e == EAGAIN or e == EWOULDBLOCK:
        return
      raise newException(NeovimError, "socket recv() failed: errno=" & $e)

proc handleIncomingData(client: NeovimClient, data: string) =
  if data.len == 0:
    return
  for msg in client.parser.feedRecovering(data):
    case msg.kind
    of rmResponse:
      client.responses[msg.msgid] = msg
      var session = client.session
      discard session.completeRequest(msg.msgid)
      client.session = session
    of rmNotification:
      client.dispatchNotification(msg)
    of rmRequest:
      discard

proc poll*(client: NeovimClient) =
  when defined(windows):
    discard
  else:
    case client.transport
    of ntkProcess:
      client.handleIncomingData(readAvailable(client.outFd))
      discard readAvailable(client.errFd) # drain to avoid blocking the child
    of ntkSocket:
      if not client.rpcSocket.isNil and not client.socketDisconnected:
        client.handleIncomingData(
          readAvailableSocket(client.rpcSocket, client.socketDisconnected)
        )
    of ntkNone:
      discard

proc waitResponse*(client: NeovimClient, msgid: uint64, timeout = 2.0): RpcMessage =
  let startTime = epochTime()
  while true:
    case client.transport
    of ntkProcess:
      if client.process != nil:
        try:
          if not client.process.running():
            raise newException(
              NeovimError, "nvim exited while waiting for response: " & $msgid
            )
        except CatchableError:
          discard
    of ntkSocket:
      when not defined(windows):
        if client.socketDisconnected:
          raise newException(
            NeovimError,
            "nvim server disconnected while waiting for response: " & $msgid,
          )
    of ntkNone:
      raise newException(NeovimError, "neovim client is not started")
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
