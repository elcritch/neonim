import std/[options, tables, unicode]

import chroma
import vmath
import figdraw/windowing/siwinshim as siwin

import ./[ui_linegrid]

const
  MouseScrollUnit = 10'f32
  PanelHighlightFill* = rgba(248, 210, 120, 36).color
  FontSizeStep* = 1.0'f32
  FontSizeMin* = 6.0'f32
  FontSizeMax* = 72.0'f32

when defined(macosx):
  const DefaultMouseScrollSpeedMultiplier* = 0.1'f32
else:
  const DefaultMouseScrollSpeedMultiplier* = 1.0'f32

type
  ModifierView* = set[siwin.ModifierKey]

  CmdShortcutAction* = enum
    csaNone
    csaCopy
    csaPaste

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

proc mouseModifierFlags*(modifiers: ModifierView): string =
  if siwin.ModifierKey.control in modifiers:
    result.add "C"
  if siwin.ModifierKey.shift in modifiers:
    result.add "S"
  if siwin.ModifierKey.alt in modifiers:
    result.add "A"
  if siwin.ModifierKey.system in modifiers:
    result.add "D"

proc mouseScrollActions*(
    delta: Vec2,
    speedMultiplier = DefaultMouseScrollSpeedMultiplier,
    invertDirection = false,
): seq[string] =
  let multiplier = max(speedMultiplier, 0.01'f32)
  let directionMultiplier = if invertDirection: -1.0'f32 else: 1.0'f32
  let x = delta.x * multiplier * directionMultiplier
  let y = delta.y * multiplier * directionMultiplier
  let ySteps = max(0, int(abs(y) / MouseScrollUnit + 0.999'f32))
  let xSteps = max(0, int(abs(x) / MouseScrollUnit + 0.999'f32))
  for _ in 0 ..< ySteps:
    result.add(if y > 0: "up" else: "down")
  for _ in 0 ..< xSteps:
    result.add(if x > 0: "left" else: "right")

proc merendaScrollDeltaToMouseScrollDelta*(deltaX, deltaY: float32): Vec2 =
  vec2(-deltaX, deltaY)

proc fontSizeDeltaForShortcut*(key: siwin.Key, modifiers: ModifierView): float32 =
  let zoomModifierDown =
    (siwin.ModifierKey.system in modifiers) or (siwin.ModifierKey.control in modifiers)
  if not zoomModifierDown:
    return 0.0'f32
  case key
  of siwin.Key.equal:
    FontSizeStep
  of siwin.Key.add:
    FontSizeStep
  of siwin.Key.minus, siwin.Key.subtract:
    -FontSizeStep
  else:
    0.0'f32

proc cmdShortcutAction*(key: siwin.Key): CmdShortcutAction =
  case key
  of siwin.Key.c: csaCopy
  of siwin.Key.v: csaPaste
  else: csaNone

proc clipboardShortcutModifierDown*(modifiers: ModifierView): bool =
  when defined(macosx):
    siwin.ModifierKey.system in modifiers
  else:
    (siwin.ModifierKey.control in modifiers) and (siwin.ModifierKey.shift in modifiers)

proc isVisualLikeMode*(mode: string): bool =
  if mode.len == 0:
    return false
  mode[0] in {'v', 'V', char(0x16), 's', 'S', char(0x13)}

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
  if attr.reverse:
    let oldFg = result.fg
    result.fg =
      if result.bg.isSome:
        result.bg.get()
      else:
        state.colors.bg
    result.bg = some(oldFg)

proc optionColor(o: Option[Color], fallback: Color): Color =
  if o.isSome:
    o.get()
  else:
    fallback

proc resolveCursorColors(
    state: LineGridState, hl: HlState, cell: Cell, style: CursorStyle
): tuple[fill: Color, text: Color] =
  let cellColors = resolveColors(state, hl, cell.hlId)
  let cellBg = optionColor(cellColors.bg, state.colors.bg)
  result.fill = cellColors.fg
  result.text = cellBg

  if style.attrId <= 0 or not hl.attrs.hasKey(style.attrId):
    return

  let attr = hl.attrs[style.attrId]
  if attr.reverse:
    result.fill = cellColors.fg
    result.text = cellBg
    return

  if attr.bg.isSome:
    result.fill = attr.bg.get()
    result.text = optionColor(attr.fg, cellBg)
  elif attr.fg.isSome:
    result.fill = attr.fg.get()
    result.text = cellBg

proc resolveCellColors*(
    state: LineGridState, hl: HlState, hlId: int64
): tuple[fg: Color, bg: Option[Color]] =
  resolveColors(state, hl, hlId)

proc resolveCursorCellColors*(
    state: LineGridState, hl: HlState, cell: Cell, style: CursorStyle
): tuple[fill: Color, text: Color] =
  resolveCursorColors(state, hl, cell, style)

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

proc panelHighlightColumns*(
    state: LineGridState
): tuple[startCol, endColExclusive: int] =
  result = (0, max(1, state.cols))
  if state.panelHighlightRow < 0 or state.panelHighlightRow >= state.rows:
    return
  if state.cursorGrid != 0 and state.winRects.hasKey(state.cursorGrid):
    let winRect = state.winRects[state.cursorGrid]
    if state.panelHighlightRow >= winRect.row and
        state.panelHighlightRow < winRect.row + winRect.rows:
      return (winRect.col, winRect.col + winRect.cols)
  result = state.fallbackPaneCols(state.panelHighlightRow, state.panelHighlightCol)
