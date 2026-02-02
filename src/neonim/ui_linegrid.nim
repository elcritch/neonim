import std/[options, streams, tables]
import msgpack4nim
import chroma

import ./rpc
import ./nvim_client

type
  Cell* = object
    text*: string
    hlId*: int64

  UiColors* = object
    fg*: Color
    bg*: Color

  LineGridState* = object
    rows*: int
    cols*: int
    cells*: seq[Cell]
    cursorRow*: int
    cursorCol*: int
    colors*: UiColors
    needsRedraw*: bool

  HlAttr* = object
    fg*: Option[Color]
    bg*: Option[Color]

  HlState* = object
    attrs*: Table[int64, HlAttr]

proc rgb24ToColor(v: int64): Color =
  let r = uint8((v shr 16) and 0xff)
  let g = uint8((v shr 8) and 0xff)
  let b = uint8(v and 0xff)
  rgba(r, g, b, 255).color

proc initLineGridState*(rows, cols: int): LineGridState =
  result.rows = rows
  result.cols = cols
  result.cells = newSeq[Cell](rows * cols)
  result.colors =
    UiColors(fg: rgba(235, 235, 235, 255).color, bg: rgba(10, 10, 10, 255).color)
  for i in 0 ..< result.cells.len:
    result.cells[i] = Cell(text: " ", hlId: 0)
  result.needsRedraw = true

proc cellIndex*(s: LineGridState, row, col: int): int =
  row * s.cols + col

proc clear*(s: var LineGridState) =
  for i in 0 ..< s.cells.len:
    s.cells[i].text = " "
    s.cells[i].hlId = 0
  s.needsRedraw = true

proc resize*(s: var LineGridState, rows, cols: int) =
  if rows == s.rows and cols == s.cols:
    return
  let old = s
  s = initLineGridState(rows, cols)
  let copyRows = min(old.rows, rows)
  let copyCols = min(old.cols, cols)
  for r in 0 ..< copyRows:
    for c in 0 ..< copyCols:
      s.cells[s.cellIndex(r, c)] = old.cells[old.cellIndex(r, c)]
  s.needsRedraw = true

proc scroll*(s: var LineGridState, top, bot, left, right, rows, cols: int) =
  # Only handles scrolling within a single grid.
  if rows == 0 and cols == 0:
    return
  var newCells = s.cells
  for r in top ..< bot:
    for c in left ..< right:
      let srcR = r - rows
      let srcC = c - cols
      let dstI = s.cellIndex(r, c)
      if srcR >= top and srcR < bot and srcC >= left and srcC < right:
        let srcI = s.cellIndex(srcR, srcC)
        newCells[dstI] = s.cells[srcI]
      else:
        newCells[dstI] = Cell(text: " ", hlId: 0)
  s.cells = newCells
  s.needsRedraw = true

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

proc handleHlAttrDefine(hl: var HlState, s: MsgStream) =
  # Each batch item: [id, rgb_attrs, cterm_attrs, info]
  let itemLen = s.unpack_array()
  if itemLen < 2:
    for _ in 0 ..< itemLen:
      s.skip_msg()
    return
  let id = unpackInt64(s)
  var attr = HlAttr(fg: none(Color), bg: none(Color))
  if s.is_map():
    let mlen = s.unpack_map()
    for _ in 0 ..< mlen:
      let key = unpackStringOrBin(s)
      case key
      of "foreground":
        attr.fg = some(rgb24ToColor(unpackInt64(s)))
      of "background":
        attr.bg = some(rgb24ToColor(unpackInt64(s)))
      else:
        s.skip_msg()
  else:
    s.skip_msg()
  # skip remaining fields (cterm_attrs, info)
  for _ in 2 ..< itemLen:
    s.skip_msg()
  hl.attrs[id] = attr

proc applyGridLine(state: var LineGridState, hl: HlState, s: MsgStream) =
  let itemLen = s.unpack_array()
  if itemLen < 4:
    for _ in 0 ..< itemLen:
      s.skip_msg()
    return
  discard unpackInt64(s) # grid
  let row = int(unpackInt64(s))
  var col = int(unpackInt64(s))

  let cellsLen = s.unpack_array()
  for _ in 0 ..< cellsLen:
    let cellLen = s.unpack_array()
    var text = unpackStringOrBin(s)
    var hlId = int64(0)
    var repeatCount = int64(1)

    if cellLen >= 2:
      hlId = unpackInt64(s)
    if cellLen >= 3:
      repeatCount = unpackInt64(s)
    for _ in 3 ..< cellLen:
      s.skip_msg()

    for _ in 0 ..< int(repeatCount):
      if row >= 0 and row < state.rows and col >= 0 and col < state.cols:
        let i = state.cellIndex(row, col)
        state.cells[i].text = if text.len == 0: " " else: text
        state.cells[i].hlId = hlId
      col.inc
  for _ in 4 ..< itemLen:
    s.skip_msg()
  state.needsRedraw = true

proc handleRedraw*(state: var LineGridState, hl: var HlState, params: RpcParamsBuffer) =
  var s = MsgStream.init(params.buf.data)
  s.setPosition(0)
  if not s.is_array():
    return
  let outerLen = s.unpack_array()
  for _ in 0 ..< outerLen:
    let evLen = s.unpack_array()
    if evLen <= 0:
      continue
    let evName = unpackStringOrBin(s)
    case evName
    of "default_colors_set":
      # [fg, bg, sp, ctermfg, ctermbg]
      for i in 1 ..< evLen:
        let itemLen = s.unpack_array()
        if itemLen >= 2:
          let fg = unpackInt64(s)
          let bg = unpackInt64(s)
          state.colors.fg =
            if fg >= 0:
              rgb24ToColor(fg)
            else:
              state.colors.fg
          state.colors.bg =
            if bg >= 0:
              rgb24ToColor(bg)
            else:
              state.colors.bg
          for _ in 2 ..< itemLen:
            s.skip_msg()
        else:
          for _ in 0 ..< itemLen:
            s.skip_msg()
      state.needsRedraw = true
    of "hl_attr_define":
      for _ in 1 ..< evLen:
        handleHlAttrDefine(hl, s)
    of "grid_resize":
      for _ in 1 ..< evLen:
        let itemLen = s.unpack_array()
        if itemLen >= 3:
          discard unpackInt64(s) # grid
          let cols = int(unpackInt64(s))
          let rows = int(unpackInt64(s))
          state.resize(rows, cols)
          for _ in 3 ..< itemLen:
            s.skip_msg()
        else:
          for _ in 0 ..< itemLen:
            s.skip_msg()
    of "grid_clear":
      for _ in 1 ..< evLen:
        let itemLen = s.unpack_array()
        if itemLen >= 1:
          discard unpackInt64(s) # grid
          state.clear()
          for _ in 1 ..< itemLen:
            s.skip_msg()
        else:
          for _ in 0 ..< itemLen:
            s.skip_msg()
    of "grid_cursor_goto":
      for _ in 1 ..< evLen:
        let itemLen = s.unpack_array()
        if itemLen >= 3:
          discard unpackInt64(s) # grid
          state.cursorRow = int(unpackInt64(s))
          state.cursorCol = int(unpackInt64(s))
          for _ in 3 ..< itemLen:
            s.skip_msg()
        else:
          for _ in 0 ..< itemLen:
            s.skip_msg()
      state.needsRedraw = true
    of "grid_scroll":
      for _ in 1 ..< evLen:
        let itemLen = s.unpack_array()
        if itemLen >= 7:
          discard unpackInt64(s) # grid
          let top = int(unpackInt64(s))
          let bot = int(unpackInt64(s))
          let left = int(unpackInt64(s))
          let right = int(unpackInt64(s))
          let rows = int(unpackInt64(s))
          let cols = int(unpackInt64(s))
          state.scroll(top, bot, left, right, rows, cols)
          for _ in 7 ..< itemLen:
            s.skip_msg()
        else:
          for _ in 0 ..< itemLen:
            s.skip_msg()
    of "grid_line":
      for _ in 1 ..< evLen:
        applyGridLine(state, hl, s)
    of "flush":
      for _ in 1 ..< evLen:
        s.skip_msg()
      state.needsRedraw = true
    else:
      for _ in 1 ..< evLen:
        s.skip_msg()
