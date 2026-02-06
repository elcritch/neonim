import std/[options, streams, tables, unittest]
import chroma
import msgpack4nim
import neonim/rpc
import neonim/ui_linegrid

proc packParams(build: proc(s: var MsgStream) {.closure.}): RpcParamsBuffer =
  var s = MsgStream.init()
  build(s)
  s.setPosition(s.data.len)
  RpcParamsBuffer(buf: s)

proc packRedraw(build: proc(s: var MsgStream) {.closure.}): RpcParamsBuffer =
  packParams(
    proc(s: var MsgStream) =
      s.pack_array(1)
      build(s)
  )

proc packEvent(
    s: var MsgStream, name: string, item: proc(s: var MsgStream) {.closure.} = nil
) =
  if item.isNil:
    s.pack_array(1)
    s.pack(name)
    return
  s.pack_array(2)
  s.pack(name)
  item(s)

suite "ui linegrid":
  test "initLineGridState initializes cells and defaults":
    var state = initLineGridState(2, 3)
    check state.rows == 2
    check state.cols == 3
    check state.cells.len == 6
    for cell in state.cells:
      check cell.text == " "
      check cell.hlId == 0
    check state.needsRedraw

  test "grid_line applies text, hlId, and repeatCount":
    var hl = HlState(attrs: initTable[int64, HlAttr]())
    var state = initLineGridState(1, 6)
    state.needsRedraw = false

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "grid_line",
          proc(s: var MsgStream) =
            s.pack_array(4)
            s.pack(0) # grid
            s.pack(0) # row
            s.pack(0) # col
            s.pack_array(2)
            s.pack_array(3)
            s.pack("a")
            s.pack(7) # hlId
            s.pack(3) # repeat
            s.pack_array(1)
            s.pack("b"),
        )
    )
    handleRedraw(state, hl, params)

    check state.needsRedraw
    check state.cells[state.cellIndex(0, 0)].text == "a"
    check state.cells[state.cellIndex(0, 1)].text == "a"
    check state.cells[state.cellIndex(0, 2)].text == "a"
    check state.cells[state.cellIndex(0, 0)].hlId == 7
    check state.cells[state.cellIndex(0, 1)].hlId == 7
    check state.cells[state.cellIndex(0, 2)].hlId == 7
    check state.cells[state.cellIndex(0, 3)].text == "b"

  test "grid_line reuses previous hlId when omitted":
    var hl = HlState(attrs: initTable[int64, HlAttr]())
    var state = initLineGridState(1, 4)

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "grid_line",
          proc(s: var MsgStream) =
            s.pack_array(4)
            s.pack(0) # grid
            s.pack(0) # row
            s.pack(0) # col
            s.pack_array(3)
            s.pack_array(2)
            s.pack("a")
            s.pack(9) # hlId
            s.pack_array(1)
            s.pack("b")
            s.pack_array(1)
            s.pack("c"),
        )
    )
    handleRedraw(state, hl, params)

    check state.cells[state.cellIndex(0, 0)].hlId == 9
    check state.cells[state.cellIndex(0, 1)].hlId == 9
    check state.cells[state.cellIndex(0, 2)].hlId == 9

  test "grid_line at nonzero col inherits existing left hlId":
    var hl = HlState(attrs: initTable[int64, HlAttr]())
    var state = initLineGridState(1, 4)
    state.cells[state.cellIndex(0, 0)].hlId = 6

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "grid_line",
          proc(s: var MsgStream) =
            s.pack_array(4)
            s.pack(0) # grid
            s.pack(0) # row
            s.pack(1) # col
            s.pack_array(1)
            s.pack_array(1)
            s.pack("x"),
        )
    )
    handleRedraw(state, hl, params)

    check state.cells[state.cellIndex(0, 1)].hlId == 6

  test "panel highlight can be cleared":
    var state = initLineGridState(2, 2)
    state.needsRedraw = false
    state.setPanelHighlight(1, 1)
    check state.panelHighlightRow == 1
    check state.panelHighlightCol == 1
    state.needsRedraw = false
    state.clearPanelHighlight()
    check state.panelHighlightRow == -1
    check state.panelHighlightCol == -1
    check state.needsRedraw

  test "grid_line treats empty text as space":
    var hl = HlState(attrs: initTable[int64, HlAttr]())
    var state = initLineGridState(1, 2)
    state.cells[state.cellIndex(0, 0)].text = "x"
    state.needsRedraw = false

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "grid_line",
          proc(s: var MsgStream) =
            s.pack_array(4)
            s.pack(0)
            s.pack(0)
            s.pack(0)
            s.pack_array(1)
            s.pack_array(1)
            s.pack(""),
        )
    )
    handleRedraw(state, hl, params)

    check state.cells[state.cellIndex(0, 0)].text == " "

  test "grid_line skips extra trailing fields":
    var hl = HlState(attrs: initTable[int64, HlAttr]())
    var state = initLineGridState(1, 4)
    state.needsRedraw = false

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "grid_line",
          proc(s: var MsgStream) =
            s.pack_array(5) # includes wrap flag as 5th field
            s.pack(0)
            s.pack(0)
            s.pack(0)
            s.pack_array(1)
            s.pack_array(1)
            s.pack("z")
            s.pack(true) # wrap
          ,
        )
    )
    handleRedraw(state, hl, params)
    check state.cells[state.cellIndex(0, 0)].text == "z"

  test "grid_resize copies existing content into new grid":
    var state = initLineGridState(2, 2)
    state.cells[state.cellIndex(0, 0)].text = "X"
    var hl = HlState(attrs: initTable[int64, HlAttr]())

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "grid_resize",
          proc(s: var MsgStream) =
            s.pack_array(3)
            s.pack(0) # grid
            s.pack(4) # cols
            s.pack(3) # rows
          ,
        )
    )
    handleRedraw(state, hl, params)

    check state.rows == 3
    check state.cols == 4
    check state.cells[state.cellIndex(0, 0)].text == "X"

  test "grid_clear blanks the grid":
    var state = initLineGridState(1, 3)
    state.cells[state.cellIndex(0, 1)].text = "Q"
    var hl = HlState(attrs: initTable[int64, HlAttr]())

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "grid_clear",
          proc(s: var MsgStream) =
            s.pack_array(1)
            s.pack(0),
        )
    )
    handleRedraw(state, hl, params)

    for cell in state.cells:
      check cell.text == " "
      check cell.hlId == 0

  test "grid_cursor_goto updates cursor position":
    var state = initLineGridState(2, 2)
    var hl = HlState(attrs: initTable[int64, HlAttr]())

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "grid_cursor_goto",
          proc(s: var MsgStream) =
            s.pack_array(3)
            s.pack(0)
            s.pack(1)
            s.pack(0),
        )
    )
    handleRedraw(state, hl, params)
    check state.cursorRow == 1
    check state.cursorCol == 0

  test "grid_scroll moves cells within region and blanks uncovered area":
    var state = initLineGridState(3, 3)
    var hl = HlState(attrs: initTable[int64, HlAttr]())

    state.cells[state.cellIndex(0, 0)].text = "A"
    state.cells[state.cellIndex(1, 0)].text = "B"
    state.cells[state.cellIndex(2, 0)].text = "C"

    # rows=1 shifts content up by one row
    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "grid_scroll",
          proc(s: var MsgStream) =
            s.pack_array(7)
            s.pack(0) # grid
            s.pack(0) # top
            s.pack(3) # bot
            s.pack(0) # left
            s.pack(3) # right
            s.pack(1) # rows
            s.pack(0) # cols
          ,
        )
    )
    handleRedraw(state, hl, params)

    check state.cells[state.cellIndex(0, 0)].text == "B"
    check state.cells[state.cellIndex(1, 0)].text == "C"
    check state.cells[state.cellIndex(2, 0)].text == " "

  test "default_colors_set updates state colors":
    var state = initLineGridState(1, 1)
    var hl = HlState(attrs: initTable[int64, HlAttr]())

    let fg = 0x112233
    let bg = 0x445566
    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "default_colors_set",
          proc(s: var MsgStream) =
            s.pack_array(2)
            s.pack(fg)
            s.pack(bg),
        )
    )
    handleRedraw(state, hl, params)

    check state.colors.fg == rgba(0x11'u8, 0x22'u8, 0x33'u8, 255).color
    check state.colors.bg == rgba(0x44'u8, 0x55'u8, 0x66'u8, 255).color

  test "hl_attr_define populates hl table":
    var state = initLineGridState(1, 1)
    var hl = HlState(attrs: initTable[int64, HlAttr]())

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "hl_attr_define",
          proc(s: var MsgStream) =
            s.pack_array(4)
            s.pack(2) # id
            s.pack_map(2)
            s.pack("foreground")
            s.pack(0x0000ff)
            s.pack("background")
            s.pack(0x00ff00)
            var p: pointer = nil
            s.pack(p)
            s.pack(p),
        )
    )
    handleRedraw(state, hl, params)

    check hl.attrs.hasKey(2)
    check hl.attrs[2].fg.isSome
    check hl.attrs[2].bg.isSome
    check hl.attrs[2].fg.get == rgba(0'u8, 0'u8, 255'u8, 255).color
    check hl.attrs[2].bg.get == rgba(0'u8, 255'u8, 0'u8, 255).color

  test "flush marks state as needing redraw":
    var state = initLineGridState(1, 1)
    var hl = HlState(attrs: initTable[int64, HlAttr]())
    state.needsRedraw = false

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(s, "flush")
    )
    handleRedraw(state, hl, params)
    check state.needsRedraw

  test "cmdline_show overlays rendered bottom row":
    var state = initLineGridState(3, 10)
    var hl = HlState(attrs: initTable[int64, HlAttr]())
    state.cells[state.cellIndex(2, 0)].text = "X"

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "cmdline_show",
          proc(s: var MsgStream) =
            s.pack_array(6)
            # content: [[attr, text]]
            s.pack_array(1)
            s.pack_array(2)
            s.pack(0)
            s.pack("e ")
            s.pack(2) # pos
            s.pack(":") # firstc
            s.pack("") # prompt
            s.pack(0) # indent
            s.pack(0) # level
          ,
        )
    )
    handleRedraw(state, hl, params)
    check state.cmdlineActive
    check state.renderedCell(2, 0).text == ":"
    check state.renderedCell(2, 1).text == "e"
    check state.renderedCell(2, 2).text == " "

  test "cmdline_show parses text when chunk starts with string":
    var state = initLineGridState(2, 12)
    var hl = HlState(attrs: initTable[int64, HlAttr]())

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "cmdline_show",
          proc(s: var MsgStream) =
            s.pack_array(6)
            s.pack_array(1)
            s.pack_array(2)
            s.pack("set")
            s.pack(0) # hl id
            s.pack(1) # pos
            s.pack(":") # firstc
            s.pack("") # prompt
            s.pack(0) # indent
            s.pack(0) # level
          ,
        )
    )
    handleRedraw(state, hl, params)
    check state.cmdlineActive
    check state.cmdlineText == ":set"

  test "cmdline_show combines firstc and prompt prefix":
    var state = initLineGridState(2, 16)
    var hl = HlState(attrs: initTable[int64, HlAttr]())

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "cmdline_show",
          proc(s: var MsgStream) =
            s.pack_array(6)
            s.pack_array(1)
            s.pack_array(2)
            s.pack(0) # hl id
            s.pack("foo")
            s.pack(3) # pos
            s.pack("?") # firstc
            s.pack("Find: ") # prompt
            s.pack(0) # indent
            s.pack(0) # level
          ,
        )
    )
    handleRedraw(state, hl, params)
    check state.cmdlineActive
    check state.cmdlineText == "?Find: foo"
    check state.cmdlineOffset == "?Find: ".len

  test "cmdline_pos updates cursor based on prefix offset":
    var state = initLineGridState(3, 10)
    var hl = HlState(attrs: initTable[int64, HlAttr]())

    let showParams = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "cmdline_show",
          proc(s: var MsgStream) =
            s.pack_array(6)
            s.pack_array(1)
            s.pack_array(2)
            s.pack(0)
            s.pack("abc")
            s.pack(2) # pos
            s.pack(":") # firstc
            s.pack("") # prompt
            s.pack(0)
            s.pack(0),
        )
    )
    handleRedraw(state, hl, showParams)
    check state.cmdlineActive
    check state.cursorRow == 2
    check state.cursorCol == 3 # offset 1 + pos 2

    let posParams = packRedraw(
      proc(s: var MsgStream) =
        packEvent(
          s,
          "cmdline_pos",
          proc(s: var MsgStream) =
            s.pack_array(1)
            s.pack(0),
        )
    )
    handleRedraw(state, hl, posParams)
    check state.cursorCol == 1

  test "cmdline_hide clears cmdline overlay":
    var state = initLineGridState(3, 10)
    var hl = HlState(attrs: initTable[int64, HlAttr]())
    state.cmdlineActive = true
    state.cmdlineText = ":q"

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(s, "cmdline_hide")
    )
    handleRedraw(state, hl, params)
    check not state.cmdlineActive
    check state.cmdlineText.len == 0
    check state.cmdlinePos == 0
    check state.cmdlineOffset == 0
    check state.cmdlineCommittedText.len == 0
    check not state.cmdlineCommitPending

  test "cmdline_hide keeps last command when commit pending":
    var state = initLineGridState(3, 12)
    var hl = HlState(attrs: initTable[int64, HlAttr]())
    state.cmdlineActive = true
    state.cmdlineText = ":write"
    state.cmdlineCommitPending = true

    let params = packRedraw(
      proc(s: var MsgStream) =
        packEvent(s, "cmdline_hide")
    )
    handleRedraw(state, hl, params)
    check not state.cmdlineActive
    check state.cmdlineCommittedText == ":write"
    check state.renderedCell(2, 0).text == ":"
    check state.renderedCell(2, 1).text == "w"
