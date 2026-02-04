when defined(emscripten):
  import std/[unicode, strutils]
else:
  import std/[os, unicode, strutils]
import std/[streams]

import chroma
import msgpack4nim
import pkg/pixie/fonts

import figdraw/[commons, fignodes, figrender, windyshim]

when not UseMetalBackend:
  import figdraw/utils/glutils

import ./[types, rpc, nvim_client, ui_linegrid]

proc monoMetrics*(font: UiFont): tuple[advance: float32, lineHeight: float32] =
  let (_, px) = font.convertFont()
  let lineH =
    if px.lineHeight >= 0:
      px.lineHeight
    else:
      px.defaultLineHeight()
  let adv = (px.typeface.getAdvance(Rune('M')) * px.scale)
  (adv, lineH/2)

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

proc buildRowLayout(
    monoFont: UiFont, state: LineGridState, row: int, x0, y0, cellW: float32
): GlyphArrangement =
  var glyphs: seq[(Rune, Vec2)]
  glyphs.setLen(state.cols)
  var x = x0
  for col in 0 ..< state.cols:
    let cell = state.cells[state.cellIndex(row, col)]
    var r: Rune = Rune(' ')
    for rr in cell.text.runes:
      r = rr
      break
    glyphs[col] = (r, vec2(x, y0))
    x += cellW
  placeGlyphs(monoFont, glyphs, origin = GlyphTopLeft)

proc buildOverlayLayout(
    monoFont: UiFont, state: LineGridState, text: string, x0, y0, cellW: float32
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
  placeGlyphs(monoFont, glyphs, origin = GlyphTopLeft)

proc makeRenderTree*(
    w, h: float32, monoFont: UiFont, state: LineGridState, cellW, cellH: float32
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
    let y = row.float32 * cellH
    let layout = buildRowLayout(monoFont, state, row, 0'f32, y, cellW)
    discard renders.addChild(
      baseZ,
      rootIdx,
      Fig(
        kind: nkText,
        childCount: 0,
        zlevel: baseZ,
        screenBox: rect(0, y, w, cellH),
        fill: state.colors.fg,
        textLayout: layout,
      ),
    )

  if state.wildmenuActive and state.rows >= 2:
    let row = state.rows - 2
    let y = row.float32 * cellH
    let layout =
      buildOverlayLayout(monoFont, state, state.wildmenuText, 0'f32, y, cellW)
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
    let layout = buildOverlayLayout(monoFont, state, state.cmdlineText, 0'f32, y, cellW)
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

  renders.layers.sort(
    proc(x, y: auto): int =
      cmp(x[0], y[0])
  )
  result = renders
