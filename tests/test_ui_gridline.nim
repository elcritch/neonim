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

proc rowHasAt(state: LineGridState, row, col: int, text: string): bool =
  if text.len == 0:
    return true
  for i in 0 ..< text.len:
    let cc = col + i
    if row < 0 or row >= state.rows or cc < 0 or cc >= state.cols:
      return false
    let cellText = state.cells[state.cellIndex(row, cc)].text
    if cellText.len == 0 or cellText[0] != text[i]:
      return false
  true

proc rowContains(state: LineGridState, row: int, text: string): bool =
  if text.len == 0:
    return true
  if text.len > state.cols:
    return false
  for col in 0 .. (state.cols - text.len):
    if state.rowHasAt(row, col, text):
      return true
  false

proc findRowContaining(state: LineGridState, text: string): int =
  for row in 0 ..< state.rows:
    if state.rowContains(row, text):
      return row
  -1

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
        let apiInfo =
          client.callAndWait("vim_get_api_info", rpcPackParams(), timeout = 10.0)
        check apiInfo.error.isNilValue

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
              state.findRowContaining(line1[0 .. i]) != -1,
            timeout = 5.0,
          )

        sendInput("\n")
        waitUntil(
          proc(): bool =
            let row = state.findRowContaining(line1)
            row != -1 and row + 1 < state.rows and state.cellChar(row + 1, 0) != '~',
          timeout = 5.0,
        )

        for i, ch in line2:
          sendInput($ch)
          waitUntil(
            proc(): bool =
              let row = state.findRowContaining(line1)
              row != -1 and row + 1 < state.rows and
                state.rowContains(row + 1, line2[0 .. i]),
            timeout = 5.0,
          )

        sendInput("\x1b")
        waitUntil(
          proc(): bool =
            let row = state.findRowContaining(line1)
            row != -1 and row + 1 < state.rows and state.rowContains(row + 1, line2),
          timeout = 5.0,
        )

  test "deleted line scrolls up and clears old content":
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
        let apiInfo =
          client.callAndWait("vim_get_api_info", rpcPackParams(), timeout = 10.0)
        check apiInfo.error.isNilValue

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

        discard client.callAndWait(
          "nvim_command",
          rpcPackParams("call setline(1, ['one', 'two', 'three'])"),
          timeout = 10.0,
        )
        discard
          client.callAndWait("nvim_command", rpcPackParams("normal! G"), timeout = 10.0)

        waitUntil(
          proc(): bool =
            let oneRow = state.findRowContaining("one")
            let twoRow = state.findRowContaining("two")
            let threeRow = state.findRowContaining("three")
            oneRow != -1 and twoRow != -1 and threeRow != -1 and threeRow == twoRow + 1,
          timeout = 5.0,
        )

        let delResp =
          client.callAndWait("nvim_input", rpcPackParams("kdd"), timeout = 10.0)
        check delResp.error.isNilValue

        waitUntil(
          proc(): bool =
            let oneRow = state.findRowContaining("one")
            if oneRow == -1 or oneRow + 1 >= state.rows:
              return false
            state.rowContains(oneRow + 1, "three") and
              state.findRowContaining("two") == -1,
          timeout = 5.0,
        )
