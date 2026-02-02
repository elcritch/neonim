import std/[os, streams, times, unittest]
import neonim/nvim_client
import neonim/rpc
import msgpack4nim

proc rpcPackUiAttachParams(
    cols, rows: int, opts: openArray[(string, bool)]
): RpcParamsBuffer =
  var s = MsgStream.init()
  s.pack_array(3)
  s.pack(cols)
  s.pack(rows)
  s.pack_map(opts.len)
  for (k, v) in opts:
    s.pack(k)
    s.pack(v)
  s.setPosition(s.data.len)
  RpcParamsBuffer(buf: s)

proc unpackInt64(s: MsgStream): int64 =
  if s.is_uint():
    var u: uint64
    s.unpack(u)
    return int64(u)
  if s.is_int():
    var i: int64
    s.unpack(i)
    return i
  raise newException(ValueError, "expected integer")

proc unpackStringOrBin(s: MsgStream): string =
  if s.is_string():
    let len = s.unpack_string()
    if len < 0:
      raise newException(ValueError, "expected string")
    return s.readExactStr(len)
  if s.is_bin():
    let len = s.unpack_bin()
    return s.readExactStr(len)
  raise newException(ValueError, "expected string/bin")

proc parseRedrawCmdlineShows(params: RpcParamsBuffer): seq[string] =
  var s = MsgStream.init(params.buf.data)
  s.setPosition(0)
  if not s.is_array():
    return

  let outerLen = s.unpack_array()
  for _ in 0 ..< outerLen:
    if not s.is_array():
      s.skip_msg()
      continue

    let evLen = s.unpack_array()
    if evLen <= 0:
      continue

    let evName = unpackStringOrBin(s)
    if evName != "cmdline_show":
      for _ in 1 ..< evLen:
        s.skip_msg()
      continue

    for _ in 1 ..< evLen:
      if not s.is_array():
        s.skip_msg()
        continue

      let argLen = s.unpack_array()
      var firstc = 0'i64
      var prompt = ""
      var contentText = ""

      for idx in 0 ..< argLen:
        case idx
        of 0:
          if not s.is_array():
            s.skip_msg()
          else:
            let chunkCount = s.unpack_array()
            for _ in 0 ..< chunkCount:
              if not s.is_array():
                s.skip_msg()
                continue
              let chunkLen = s.unpack_array()
              for cidx in 0 ..< chunkLen:
                if cidx == 1:
                  if s.is_string() or s.is_bin():
                    contentText.add unpackStringOrBin(s)
                  else:
                    s.skip_msg()
                else:
                  s.skip_msg()
        of 2:
          if s.is_uint() or s.is_int():
            firstc = unpackInt64(s)
          elif s.is_string() or s.is_bin():
            let firstcStr = unpackStringOrBin(s)
            if firstcStr.len > 0:
              firstc = ord(firstcStr[0])
          else:
            s.skip_msg()
        of 3:
          if s.is_string() or s.is_bin():
            prompt = unpackStringOrBin(s)
          else:
            s.skip_msg()
        else:
          s.skip_msg()

      var leading = ""
      if firstc > 0 and firstc <= 255:
        leading = $char(firstc)
      result.add leading & prompt & contentText

suite "neovim client":
  test "basic text input":
    when defined(windows):
      check true
    else:
      if findExe("nvim").len == 0:
        echo "SKIP: `nvim` not found in PATH"
        check true
      else:
        let client = newNeovimClient()
        defer:
          client.stop()

        client.start(
          nvimCmd = "nvim",
          args = @["--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-n"],
        )

        discard client.discoverMetadata()

        let inputResp =
          client.callAndWait("nvim_input", rpcPackParams("ihello\x1b"), timeout = 10.0)
        check inputResp.error.isNilValue
        check rpcUnpack[int](inputResp.result) > 0

        let lineResp =
          client.callAndWait("nvim_get_current_line", rpcPackParams(), timeout = 10.0)
        check lineResp.error.isNilValue
        check rpcUnpack[string](lineResp.result) == "hello"

  test "colon command via input":
    when defined(windows):
      check true
    else:
      if findExe("nvim").len == 0:
        echo "SKIP: `nvim` not found in PATH"
        check true
      else:
        let client = newNeovimClient()
        defer:
          client.stop()

        client.start(
          nvimCmd = "nvim",
          args = @["--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-n"],
        )
        discard client.discoverMetadata()

        let setVarResp = client.callAndWait(
          "nvim_input", rpcPackParams(":let g:neonim_test_var='ok'\n"), timeout = 10.0
        )
        check setVarResp.error.isNilValue

        let getVarResp = client.callAndWait(
          "nvim_get_var", rpcPackParams("neonim_test_var"), timeout = 10.0
        )
        check getVarResp.error.isNilValue
        check rpcUnpack[string](getVarResp.result) == "ok"

  test "nvim_command executes ex":
    when defined(windows):
      check true
    else:
      if findExe("nvim").len == 0:
        echo "SKIP: `nvim` not found in PATH"
        check true
      else:
        let client = newNeovimClient()
        defer:
          client.stop()

        client.start(
          nvimCmd = "nvim",
          args = @["--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-n"],
        )
        discard client.discoverMetadata()

        let cmdResp = client.callAndWait(
          "nvim_command",
          rpcPackParams("call setline(1, 'via-command')"),
          timeout = 10.0,
        )
        check cmdResp.error.isNilValue

        let lineResp =
          client.callAndWait("nvim_get_current_line", rpcPackParams(), timeout = 10.0)
        check lineResp.error.isNilValue
        check rpcUnpack[string](lineResp.result) == "via-command"

  test ":q exits":
    when defined(windows):
      check true
    else:
      if findExe("nvim").len == 0:
        echo "SKIP: `nvim` not found in PATH"
        check true
      else:
        let client = newNeovimClient()
        defer:
          client.stop()

        client.start(
          nvimCmd = "nvim",
          args = @["--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-n"],
        )
        discard client.discoverMetadata()

        client.notify("nvim_input", rpcPackParams(":q\n"))
        check client.waitForExit(timeout = 5.0)

  test "cmdline text redraw from char-by-char input":
    when defined(windows):
      check true
    else:
      if findExe("nvim").len == 0:
        echo "SKIP: `nvim` not found in PATH"
        check true
      else:
        let client = newNeovimClient()
        defer:
          client.stop()

        client.start(
          nvimCmd = "nvim",
          args = @["--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-n"],
        )
        discard client.discoverMetadata()

        var lastCmdline = ""

        let attachResp = client.callAndWait(
          "nvim_ui_attach",
          rpcPackUiAttachParams(80, 24, [("ext_cmdline", true)]),
          timeout = 10.0,
        )
        check attachResp.error.isNilValue

        proc waitForCmdline(expected: string, timeout = 2.0) =
          let startTime = epochTime()
          while true:
            client.poll()
            for notif in client.takeNotifications():
              if notif.kind == rmNotification and notif.methodName == "redraw":
                let shows = parseRedrawCmdlineShows(notif.params)
                if shows.len > 0:
                  lastCmdline = shows[^1]
            if lastCmdline == expected:
              return
            if epochTime() - startTime > timeout:
              break
            sleep(1)
          check lastCmdline == expected

        let typed = ":set number"
        for i, ch in typed:
          let resp =
            client.callAndWait("nvim_input", rpcPackParams($ch), timeout = 10.0)
          check resp.error.isNilValue
          waitForCmdline(typed[0 .. i])

        discard client.callAndWait("nvim_input", rpcPackParams("\x1b"), timeout = 10.0)
