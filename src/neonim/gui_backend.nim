when defined(emscripten):
  import std/[unicode, options, tables]
else:
  import std/[unicode, options, tables]

import chroma
import pkg/pixie/fonts
import figdraw/windowing/siwinshim as siwin

import figdraw/[commons, fignodes, figrender]
import figdraw/common/fonttypes

when not UseMetalBackend:
  import figdraw/utils/glutils

import ./[ui_linegrid]

const
  MouseScrollUnit = 10'f32
  DefaultMouseScrollSpeedMultiplier* = 1.0'f32
  PanelHighlightFill* = rgba(248, 210, 120, 36).color
  UiScaleStep* = 0.05'f32
  UiScaleMin* = 0.5'f32
  UiScaleMax* = 4.0'f32

type
  ModifierView* = set[siwin.ModifierKey]
  MouseButtonView* = set[siwin.MouseButton]

  CmdShortcutAction* = enum
    csaNone
    csaCopy
    csaPaste

proc monoMetrics*(font: FigFont): tuple[advance: float32, lineHeight: float32] =
  let (_, px) = font.convertFont()
  let lineH =
    if px.lineHeight >= 0:
      px.lineHeight
    else:
      px.defaultLineHeight()
  let adv = (px.typeface.getAdvance(Rune('M')) * px.scale)
  (adv, lineH / 2)

proc ctrlKeyToNvimInput(key: siwin.Key): string =
  case key
  of siwin.Key.a: "<C-a>"
  of siwin.Key.b: "<C-b>"
  of siwin.Key.c: "<C-c>"
  of siwin.Key.d: "<C-d>"
  of siwin.Key.e: "<C-e>"
  of siwin.Key.f: "<C-f>"
  of siwin.Key.g: "<C-g>"
  of siwin.Key.h: "<C-h>"
  of siwin.Key.i: "<C-i>"
  of siwin.Key.j: "<C-j>"
  of siwin.Key.k: "<C-k>"
  of siwin.Key.l: "<C-l>"
  of siwin.Key.m: "<C-m>"
  of siwin.Key.n: "<C-n>"
  of siwin.Key.o: "<C-o>"
  of siwin.Key.p: "<C-p>"
  of siwin.Key.q: "<C-q>"
  of siwin.Key.r: "<C-r>"
  of siwin.Key.s: "<C-s>"
  of siwin.Key.t: "<C-t>"
  of siwin.Key.u: "<C-u>"
  of siwin.Key.v: "<C-v>"
  of siwin.Key.w: "<C-w>"
  of siwin.Key.x: "<C-x>"
  of siwin.Key.y: "<C-y>"
  of siwin.Key.z: "<C-z>"
  else: ""

proc withAltModifier(input: string): string =
  if input.len == 0:
    return ""
  if input.len >= 2 and input[0] == '<' and input[^1] == '>':
    return "<A-" & input[1 .. ^2] & ">"
  "<A-" & input & ">"

proc keyToTextInput(key: siwin.Key, shiftDown: bool): string =
  case key
  of siwin.Key.a:
    return (if shiftDown: "A" else: "a")
  of siwin.Key.b:
    return (if shiftDown: "B" else: "b")
  of siwin.Key.c:
    return (if shiftDown: "C" else: "c")
  of siwin.Key.d:
    return (if shiftDown: "D" else: "d")
  of siwin.Key.e:
    return (if shiftDown: "E" else: "e")
  of siwin.Key.f:
    return (if shiftDown: "F" else: "f")
  of siwin.Key.g:
    return (if shiftDown: "G" else: "g")
  of siwin.Key.h:
    return (if shiftDown: "H" else: "h")
  of siwin.Key.i:
    return (if shiftDown: "I" else: "i")
  of siwin.Key.j:
    return (if shiftDown: "J" else: "j")
  of siwin.Key.k:
    return (if shiftDown: "K" else: "k")
  of siwin.Key.l:
    return (if shiftDown: "L" else: "l")
  of siwin.Key.m:
    return (if shiftDown: "M" else: "m")
  of siwin.Key.n:
    return (if shiftDown: "N" else: "n")
  of siwin.Key.o:
    return (if shiftDown: "O" else: "o")
  of siwin.Key.p:
    return (if shiftDown: "P" else: "p")
  of siwin.Key.q:
    return (if shiftDown: "Q" else: "q")
  of siwin.Key.r:
    return (if shiftDown: "R" else: "r")
  of siwin.Key.s:
    return (if shiftDown: "S" else: "s")
  of siwin.Key.t:
    return (if shiftDown: "T" else: "t")
  of siwin.Key.u:
    return (if shiftDown: "U" else: "u")
  of siwin.Key.v:
    return (if shiftDown: "V" else: "v")
  of siwin.Key.w:
    return (if shiftDown: "W" else: "w")
  of siwin.Key.x:
    return (if shiftDown: "X" else: "x")
  of siwin.Key.y:
    return (if shiftDown: "Y" else: "y")
  of siwin.Key.z:
    return (if shiftDown: "Z" else: "z")
  of siwin.Key.n0:
    return "0"
  of siwin.Key.n1:
    return "1"
  of siwin.Key.n2:
    return "2"
  of siwin.Key.n3:
    return "3"
  of siwin.Key.n4:
    return "4"
  of siwin.Key.n5:
    return "5"
  of siwin.Key.n6:
    return "6"
  of siwin.Key.n7:
    return "7"
  of siwin.Key.n8:
    return "8"
  of siwin.Key.n9:
    return "9"
  of siwin.Key.space:
    return " "
  of siwin.Key.tilde:
    return (if shiftDown: "~" else: "`")
  of siwin.Key.minus:
    return (if shiftDown: "_" else: "-")
  of siwin.Key.equal:
    return (if shiftDown: "+" else: "=")
  of siwin.Key.lbracket:
    return (if shiftDown: "{" else: "[")
  of siwin.Key.rbracket:
    return (if shiftDown: "}" else: "]")
  of siwin.Key.backslash:
    return (if shiftDown: "|" else: "\\")
  of siwin.Key.semicolon:
    return (if shiftDown: ":" else: ";")
  of siwin.Key.quote:
    return (if shiftDown: "\"" else: "'")
  of siwin.Key.comma:
    return (if shiftDown: "<" else: ",")
  of siwin.Key.dot:
    return (if shiftDown: ">" else: ".")
  of siwin.Key.slash:
    return (if shiftDown: "?" else: "/")
  else:
    return ""

proc keyToNvimInput*(
    key: siwin.Key, ctrlDown: bool, altDown = false, shiftDown = false
): string =
  if ctrlDown:
    let ctrlInput = ctrlKeyToNvimInput(key)
    if ctrlInput.len > 0:
      return
        if altDown:
          withAltModifier(ctrlInput)
        else:
          ctrlInput
  let input =
    case key
    of siwin.Key.enter: "<CR>"
    of siwin.Key.backspace: "<BS>"
    of siwin.Key.tab: "<Tab>"
    of siwin.Key.escape: "<Esc>"
    of siwin.Key.up: "<Up>"
    of siwin.Key.down: "<Down>"
    of siwin.Key.left: "<Left>"
    of siwin.Key.right: "<Right>"
    of siwin.Key.del: "<Del>"
    of siwin.Key.home: "<Home>"
    of siwin.Key.End: "<End>"
    of siwin.Key.pageUp: "<PageUp>"
    of siwin.Key.pageDown: "<PageDown>"
    else: ""
  if altDown:
    if input.len > 0:
      return withAltModifier(input)
    let textInput = keyToTextInput(key, shiftDown)
    if textInput.len > 0:
      return withAltModifier(textInput)
    return ""
  input

proc runeToNvimInput*(r: Rune): string =
  if r == Rune('<'):
    return "<LT>"
  $r

proc mouseButtonToNvimButton*(button: siwin.MouseButton): string =
  case button
  of siwin.MouseButton.left: "left"
  of siwin.MouseButton.right: "right"
  of siwin.MouseButton.middle: "middle"
  of siwin.MouseButton.forward: "x1"
  of siwin.MouseButton.backward: "x2"

proc multiClickToNvimInput*(clickCount, row, col: int): string =
  if clickCount < 2 or clickCount > 4:
    return ""
  "<" & $clickCount & "-LeftMouse><" & $col & "," & $row & ">"

proc mouseDragButtonToNvimButton*(buttons: MouseButtonView): string =
  if siwin.MouseButton.left in buttons:
    return "left"
  if siwin.MouseButton.right in buttons:
    return "right"
  if siwin.MouseButton.middle in buttons:
    return "middle"
  if siwin.MouseButton.forward in buttons:
    return "x1"
  if siwin.MouseButton.backward in buttons:
    return "x2"
  ""

proc mouseModifierFlags*(modifiers: ModifierView): string =
  if siwin.ModifierKey.control in modifiers:
    result.add "C"
  if siwin.ModifierKey.shift in modifiers:
    result.add "S"
  if siwin.ModifierKey.alt in modifiers:
    result.add "A"
  if siwin.ModifierKey.system in modifiers:
    result.add "D"

proc mouseGridCell*(
    mousePos: Vec2, rows, cols: int, cellW, cellH: float32
): tuple[row, col: int] =
  if rows <= 0 or cols <= 0 or cellW <= 0 or cellH <= 0:
    return (0, 0)
  let rawCol = int(mousePos.x / cellW)
  let rawRow = int(mousePos.y / (2 * cellH))
  result.col = min(cols - 1, max(0, rawCol))
  result.row = min(rows - 1, max(0, rawRow))

proc mouseScrollActions*(
    delta: Vec2, speedMultiplier = DefaultMouseScrollSpeedMultiplier
): seq[string] =
  let multiplier = max(speedMultiplier, 0.01'f32)
  let x = delta.x * multiplier
  let y = delta.y * multiplier
  let ySteps = max(0, int(abs(y) / MouseScrollUnit + 0.999'f32))
  let xSteps = max(0, int(abs(x) / MouseScrollUnit + 0.999'f32))
  for _ in 0 ..< ySteps:
    result.add(if y > 0: "up" else: "down")
  for _ in 0 ..< xSteps:
    result.add(if x > 0: "left" else: "right")

proc uiScaleDeltaForShortcut*(key: siwin.Key, modifiers: ModifierView): float32 =
  let zoomModifierDown =
    (siwin.ModifierKey.system in modifiers) or (siwin.ModifierKey.control in modifiers)
  if not zoomModifierDown:
    return 0.0'f32
  case key
  of siwin.Key.equal:
    UiScaleStep
  of siwin.Key.add:
    UiScaleStep
  of siwin.Key.minus, siwin.Key.subtract:
    -UiScaleStep
  else:
    0.0'f32

proc cmdShortcutAction*(key: siwin.Key): CmdShortcutAction =
  case key
  of siwin.Key.c: csaCopy
  of siwin.Key.v: csaPaste
  else: csaNone

proc isVisualLikeMode*(mode: string): bool =
  if mode.len == 0:
    return false
  mode[0] in {'v', 'V', char(0x16), 's', 'S', char(0x13)}

proc buildOverlayLayout(
    monoFont: FigFont,
    state: LineGridState,
    text: string,
    fg: Color,
    x0, y0, cellW: float32,
): GlyphArrangement =
  var glyphs: seq[(Rune, Vec2)]
  glyphs.setLen(state.cols)
  var x = x0
  for col in 0 ..< state.cols:
    var r: Rune = Rune(' ')
    if col < text.len:
      r = Rune(text[col])
    glyphs[col] = (r, vec2(x, y0))
    x += cellW
  placeGlyphs(fs(monoFont, fg), glyphs, origin = GlyphTopLeft)

proc resolveColors(
    state: LineGridState, hl: HlState, hlId: int64
): tuple[fg: Color, bg: Option[Color]] =
  result.fg = state.colors.fg
  result.bg = none(Color)
  if hlId == 0:
    return
  if not hl.attrs.hasKey(hlId):
    return
  let attr = hl.attrs[hlId]
  if attr.fg.isSome:
    result.fg = attr.fg.get()
  if attr.bg.isSome:
    let bg = attr.bg.get()
    if bg != state.colors.bg:
      result.bg = some(bg)

proc runeForCell(cell: Cell): Rune =
  for rr in cell.text.runes:
    return rr
  Rune(' ')

proc isSplitBorderRune(r: Rune): bool =
  r == Rune('|') or r == Rune(0x2502) or r == Rune(0x2503) or r == Rune(0x250A) or
    r == Rune(0x250B)

proc isSplitBorderCell(state: LineGridState, row, col: int): bool =
  if row < 0 or row >= state.rows or col < 0 or col >= state.cols:
    return false
  let rune = runeForCell(state.cells[state.cellIndex(row, col)])
  if not isSplitBorderRune(rune):
    return false
  # Treat it as a pane border only when adjacent rows share the same border rune.
  let upMatches =
    row > 0 and runeForCell(state.cells[state.cellIndex(row - 1, col)]) == rune
  let downMatches =
    row + 1 < state.rows and
    runeForCell(state.cells[state.cellIndex(row + 1, col)]) == rune
  upMatches or downMatches

proc fallbackPaneCols(
    state: LineGridState, row, col: int
): tuple[startCol, endColExclusive: int] =
  if row < 0 or row >= state.rows or state.cols <= 0:
    return (0, max(1, state.cols))

  var anchorCol = min(state.cols - 1, max(0, col))
  if state.isSplitBorderCell(row, anchorCol) and anchorCol > 0:
    anchorCol.dec

  var left = 0
  for c in countdown(anchorCol, 0):
    if state.isSplitBorderCell(row, c):
      left = c + 1
      break

  var right = state.cols
  for c in anchorCol ..< state.cols:
    if state.isSplitBorderCell(row, c):
      right = c
      break

  if right <= left:
    return (0, state.cols)
  (left, right)

proc addRowRun(
    renders: var Renders,
    baseZ: ZLevel,
    rootIdx: FigIdx,
    monoFont: FigFont,
    state: LineGridState,
    row: int,
    startCol, endCol: int,
    fg: Color,
    bg: Option[Color],
    cellW, cellH: float32,
) =
  let y = row.float32 * cellH
  let x = startCol.float32 * cellW
  let w = (endCol - startCol).float32 * cellW
  if bg.isSome:
    discard renders.addChild(
      baseZ,
      rootIdx,
      Fig(
        kind: nkRectangle,
        childCount: 0,
        zlevel: baseZ,
        screenBox: rect(x, 2 * y, w, 2 * cellH),
        fill: bg.get(),
      ),
    )

  var glyphs: seq[(Rune, Vec2)]
  glyphs.setLen(endCol - startCol)
  var gx = 0'f32
  for col in startCol ..< endCol:
    let cell = state.cells[state.cellIndex(row, col)]
    # Positions are relative to the node origin; screenBox provides the run offset.
    glyphs[col - startCol] = (runeForCell(cell), vec2(gx, y))
    gx += cellW
  let layout = placeGlyphs(fs(monoFont, fg), glyphs, origin = GlyphTopLeft)
  discard renders.addChild(
    baseZ,
    rootIdx,
    Fig(
      kind: nkText,
      childCount: 0,
      zlevel: baseZ,
      screenBox: rect(x, y, w, cellH),
      fill: fg,
      textLayout: layout,
    ),
  )

proc makeRenderTree*(
    w, h: float32,
    monoFont: FigFont,
    state: LineGridState,
    hl: HlState,
    cellW, cellH: float32,
): Renders =
  var renders = Renders()
  let baseZ = 0.ZLevel
  let overlayZ = 1.ZLevel

  let rootIdx = renders.addRoot(
    baseZ,
    Fig(
      kind: nkRectangle,
      childCount: 0,
      zlevel: baseZ,
      screenBox: rect(0, 0, w, h),
      fill: state.colors.bg,
    ),
  )

  for row in 0 ..< state.rows:
    var col = 0
    while col < state.cols:
      let cell = state.cells[state.cellIndex(row, col)]
      let colors = resolveColors(state, hl, cell.hlId)
      let runFg = colors.fg
      let runBg = colors.bg
      var endCol = col + 1
      while endCol < state.cols:
        let nextCell = state.cells[state.cellIndex(row, endCol)]
        let nextColors = resolveColors(state, hl, nextCell.hlId)
        if nextColors.fg != runFg or nextColors.bg != runBg:
          break
        endCol.inc
      addRowRun(
        renders, baseZ, rootIdx, monoFont, state, row, col, endCol, runFg, runBg, cellW,
        cellH,
      )
      col = endCol

  if state.wildmenuActive and state.rows >= 2:
    let row = state.rows - 2
    let y = row.float32 * cellH
    discard renders.addRoot(
      overlayZ,
      Fig(
        kind: nkRectangle,
        childCount: 0,
        zlevel: overlayZ,
        screenBox: rect(0, 2 * y, w, 2 * cellH),
        fill: state.colors.bg,
      ),
    )
    let layout = buildOverlayLayout(
      monoFont, state, state.wildmenuText, state.colors.fg, 0'f32, y, cellW
    )
    discard renders.addRoot(
      overlayZ,
      Fig(
        kind: nkText,
        childCount: 0,
        zlevel: overlayZ,
        screenBox: rect(0, y, w, cellH),
        fill: state.colors.fg,
        textLayout: layout,
      ),
    )

  if state.cmdlineActive:
    let row = state.rows - 1
    let y = row.float32 * cellH
    discard renders.addRoot(
      overlayZ,
      Fig(
        kind: nkRectangle,
        childCount: 0,
        zlevel: overlayZ,
        screenBox: rect(0, 2 * y, w, 2 * cellH),
        fill: state.colors.bg,
      ),
    )
    let layout = buildOverlayLayout(
      monoFont, state, state.cmdlineText, state.colors.fg, 0'f32, y, cellW
    )
    discard renders.addRoot(
      overlayZ,
      Fig(
        kind: nkText,
        childCount: 0,
        zlevel: overlayZ,
        screenBox: rect(0, y, w, cellH),
        fill: state.colors.fg,
        textLayout: layout,
      ),
    )

  if state.panelHighlightRow >= 0 and state.panelHighlightRow < state.rows:
    let py = state.panelHighlightRow.float32 * 2 * cellH
    var px = 0'f32
    var pw = w
    var usedWinRect = false
    if state.cursorGrid != 0 and state.winRects.hasKey(state.cursorGrid):
      let winRect = state.winRects[state.cursorGrid]
      if state.panelHighlightRow >= winRect.row and
          state.panelHighlightRow < winRect.row + winRect.rows:
        px = winRect.col.float32 * cellW
        pw = winRect.cols.float32 * cellW
        usedWinRect = true
    if not usedWinRect:
      let (startCol, endColExclusive) =
        state.fallbackPaneCols(state.panelHighlightRow, state.panelHighlightCol)
      px = startCol.float32 * cellW
      pw = max(1, endColExclusive - startCol).float32 * cellW
    discard renders.addRoot(
      overlayZ,
      Fig(
        kind: nkRectangle,
        childCount: 0,
        zlevel: overlayZ,
        screenBox: rect(px, py, pw, 2 * cellH),
        fill: PanelHighlightFill,
      ),
    )

  if state.cursorRow >= 0 and state.cursorRow < state.rows and state.cursorCol >= 0 and
      state.cursorCol < state.cols:
    let cx = state.cursorCol.float32 * cellW
    let cy = state.cursorRow.float32 * 2 * cellH
    discard renders.addRoot(
      overlayZ,
      Fig(
        kind: nkRectangle,
        childCount: 0,
        zlevel: overlayZ,
        screenBox: rect(cx, cy, cellW, 2 * cellH),
        fill: rgba(220, 220, 220, 80).color,
      ),
    )

  result = renders
