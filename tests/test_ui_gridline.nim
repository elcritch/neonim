import std/[os, streams, tables, times, unittest]
import msgpack4nim
import neonim/nvim_client
import neonim/rpc
import neonim/ui_linegrid

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

proc rowStartsWith(state: LineGridState, row: int, prefix: string): bool =
  for i in 0 ..< prefix.len:
    if row < 0 or row >= state.rows or i < 0 or i >= state.cols:
      return false
    let cellText = state.cells[state.cellIndex(row, i)].text
    if cellText.len == 0 or cellText[0] != prefix[i]:
      return false
  true

proc cellChar(state: LineGridState, row, col: int): char =
  if row < 0 or row >= state.rows or col < 0 or col >= state.cols:
    return '\0'
  let cellText = state.cells[state.cellIndex(row, col)].text
  if cellText.len == 0:
    return '\0'
  cellText[0]

suite "ui linegrid redraw":
  test "multiline insert updates grid rendering":
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

        var hl = HlState(attrs: initTable[int64, HlAttr]())
        var state = initLineGridState(24, 80)

        proc pumpAndHandleRedraw() =
          client.poll()
          for notif in client.takeNotifications():
            if notif.kind == rmNotification and notif.methodName == "redraw":
              handleRedraw(state, hl, notif.params)

        proc waitUntil(predicate: proc(): bool {.closure.}, timeout = 2.0) =
          let startTime = epochTime()
          while true:
            pumpAndHandleRedraw()
            if predicate():
              return
            if epochTime() - startTime > timeout:
              break
            sleep(1)
          check predicate()

        let attachResp = client.callAndWait(
          "nvim_ui_attach",
          rpcPackUiAttachParams(
            80, 24, [("rgb", true), ("ext_linegrid", true), ("ext_hlstate", true)]
          ),
          timeout = 10.0,
        )
        check attachResp.error.isNilValue

        for _ in 0 ..< 50:
          pumpAndHandleRedraw()

        proc sendInput(s: string) =
          let resp = client.callAndWait("nvim_input", rpcPackParams(s), timeout = 10.0)
          check resp.error.isNilValue
          check rpcUnpack[int](resp.result) > 0

        discard client.callAndWait(
          "nvim_command", rpcPackParams("normal! gg0"), timeout = 10.0
        )

        sendInput("i")

        let line1 = "hello"
        let line2 = "world"

        for i, ch in line1:
          sendInput($ch)
          waitUntil(
            proc(): bool =
              state.rowStartsWith(0, line1[0 .. i])
          )

        sendInput("\n")
        waitUntil(
          proc(): bool =
            state.rowStartsWith(0, line1) and state.cellChar(1, 0) != '~'
        )

        for i, ch in line2:
          sendInput($ch)
          waitUntil(
            proc(): bool =
              state.rowStartsWith(1, line2[0 .. i])
          )

        sendInput("\x1b")
        waitUntil(
          proc(): bool =
            state.rowStartsWith(0, line1) and state.rowStartsWith(1, line2)
        )
