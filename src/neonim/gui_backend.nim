when defined(emscripten):
  import std/[unicode, options, tables]
else:
  import std/[unicode, options, tables]

import chroma
import pkg/pixie/fonts

import figdraw/[commons, fignodes, figrender, windyshim]
import figdraw/common/fonttypes

when not UseMetalBackend:
  import figdraw/utils/glutils

import ./[ui_linegrid]

const
  MouseScrollUnit = 10'f32
  PanelHighlightFill* = rgba(248, 210, 120, 36).color
  UiScaleStep* = 0.05'f32
  UiScaleMin* = 0.5'f32
  UiScaleMax* = 4.0'f32

proc monoMetrics*(font: FigFont): tuple[advance: float32, lineHeight: float32] =
  let (_, px) = font.convertFont()
  let lineH =
    if px.lineHeight >= 0:
      px.lineHeight
    else:
      px.defaultLineHeight()
  let adv = (px.typeface.getAdvance(Rune('M')) * px.scale)
  (adv, lineH / 2)

proc ctrlKeyToNvimInput(button: Button): string =
  case button
  of KeyA: "<C-a>"
  of KeyB: "<C-b>"
  of KeyC: "<C-c>"
  of KeyD: "<C-d>"
  of KeyE: "<C-e>"
  of KeyF: "<C-f>"
  of KeyG: "<C-g>"
  of KeyH: "<C-h>"
  of KeyI: "<C-i>"
  of KeyJ: "<C-j>"
  of KeyK: "<C-k>"
  of KeyL: "<C-l>"
  of KeyM: "<C-m>"
  of KeyN: "<C-n>"
  of KeyO: "<C-o>"
  of KeyP: "<C-p>"
  of KeyQ: "<C-q>"
  of KeyR: "<C-r>"
  of KeyS: "<C-s>"
  of KeyT: "<C-t>"
  of KeyU: "<C-u>"
  of KeyV: "<C-v>"
  of KeyW: "<C-w>"
  of KeyX: "<C-x>"
  of KeyY: "<C-y>"
  of KeyZ: "<C-z>"
  else: ""

proc keyToNvimInput*(button: Button, ctrlDown: bool): string =
  if ctrlDown:
    let ctrlInput = ctrlKeyToNvimInput(button)
    if ctrlInput.len > 0:
      return ctrlInput
  case button
  of KeyEnter: "<CR>"
  of KeyBackspace: "<BS>"
  of KeyTab: "<Tab>"
  of KeyEscape: "<Esc>"
  of KeyUp: "<Up>"
  of KeyDown: "<Down>"
  of KeyLeft: "<Left>"
  of KeyRight: "<Right>"
  of KeyDelete: "<Del>"
  of KeyHome: "<Home>"
  of KeyEnd: "<End>"
  of KeyPageUp: "<PageUp>"
  of KeyPageDown: "<PageDown>"
  else: ""

proc mouseButtonToNvimButton*(button: Button): string =
  case button
  of MouseLeft: "left"
  of MouseRight: "right"
  of MouseMiddle: "middle"
  of MouseButton4: "x1"
  of MouseButton5: "x2"
  else: ""

proc mouseDragButtonToNvimButton*(buttons: ButtonView): string =
  if buttons[MouseLeft]:
    return "left"
  if buttons[MouseRight]:
    return "right"
  if buttons[MouseMiddle]:
    return "middle"
  if buttons[MouseButton4]:
    return "x1"
  if buttons[MouseButton5]:
    return "x2"
  ""

proc mouseModifierFlags*(buttons: ButtonView): string =
  if buttons[KeyLeftControl] or buttons[KeyRightControl]:
    result.add "C"
  if buttons[KeyLeftShift] or buttons[KeyRightShift]:
    result.add "S"
  if buttons[KeyLeftAlt] or buttons[KeyRightAlt]:
    result.add "A"
  if buttons[KeyLeftSuper] or buttons[KeyRightSuper]:
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

proc mouseScrollActions*(delta: Vec2): seq[string] =
  let x = delta.x
  let y = delta.y
  let ySteps = max(0, int(abs(y) / MouseScrollUnit + 0.999'f32))
  let xSteps = max(0, int(abs(x) / MouseScrollUnit + 0.999'f32))
  for _ in 0 ..< ySteps:
    result.add(if y > 0: "up" else: "down")
  for _ in 0 ..< xSteps:
    result.add(if x > 0: "left" else: "right")

proc uiScaleDeltaForShortcut*(button: Button, buttons: ButtonView): float32 =
  let superDown = buttons[KeyLeftSuper] or buttons[KeyRightSuper]
  if not superDown:
    return 0.0'f32
  case button
  of KeyEqual, NumpadAdd:
    UiScaleStep
  of KeyMinus, NumpadSubtract:
    -UiScaleStep
  else:
    0.0'f32

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
    discard renders.addRoot(
      overlayZ,
      Fig(
        kind: nkRectangle,
        childCount: 0,
        zlevel: overlayZ,
        screenBox: rect(0, py, w, 2 * cellH),
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
