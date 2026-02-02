when defined(emscripten):
  import std/[unicode]
else:
  import std/[os, unicode]
import std/[streams]

import chroma
import msgpack4nim
import pkg/pixie/fonts

import figdraw/commons
import figdraw/fignodes
import figdraw/figrender as glrenderer
import figdraw/windyshim
when not UseMetalBackend:
  import figdraw/utils/glutils

import ./rpc
import ./nvim_client
import ./ui_linegrid

type
  GuiConfig* = object
    nvimCmd*: string
    nvimArgs*: seq[string]
    windowTitle*: string

    fontTypeface*: string
    fontSize*: float32
    lineHeightScale*: float32

proc monoMetrics(font: UiFont): tuple[advance: float32, lineHeight: float32] =
  let (_, px) = font.convertFont()
  let lineH =
    (if px.lineHeight >= 0: px.lineHeight else: px.defaultLineHeight()).descaled()
  let adv = (px.typeface.getAdvance(Rune('M')) * px.scale).descaled()
  (adv, lineH)

proc keyToNvimInput(button: Button): string =
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

proc buildRowLayout(monoFont: UiFont, state: LineGridState, row: int, x0, y0, cellW: float32): GlyphArrangement =
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

proc makeRenderTree(w, h: float32, monoFont: UiFont, state: LineGridState, cellW, cellH: float32): Renders =
  var list = RenderList()

  let rootIdx = list.addRoot(
    Fig(
      kind: nkRectangle,
      childCount: 0,
      zlevel: 0.ZLevel,
      screenBox: rect(0, 0, w, h),
      fill: state.colors.bg,
    )
  )

  for row in 0 ..< state.rows:
    let y = row.float32 * cellH
    let layout = buildRowLayout(monoFont, state, row, 0'f32, y, cellW)
    discard list.addChild(
      rootIdx,
      Fig(
        kind: nkText,
        childCount: 0,
        zlevel: 0.ZLevel,
        screenBox: rect(0, y, w, cellH),
        fill: state.colors.fg,
        textLayout: layout,
      ),
    )

  if state.cursorRow >= 0 and state.cursorRow < state.rows and
     state.cursorCol >= 0 and state.cursorCol < state.cols:
    let cx = state.cursorCol.float32 * cellW
    let cy = state.cursorRow.float32 * cellH
    discard list.addChild(
      rootIdx,
      Fig(
        kind: nkRectangle,
        childCount: 0,
        zlevel: 1.ZLevel,
        screenBox: rect(cx, cy, cellW, cellH),
        fill: rgba(220, 220, 220, 80).color,
      ),
    )

  result = Renders(layers: initOrderedTable[ZLevel, RenderList]())
  result.layers[0.ZLevel] = list

proc computeGridSize(win: WindowInfo, cellW, cellH: float32): tuple[rows, cols: int] =
  let cols = max(1, int(win.box.w / cellW))
  let rows = max(1, int(win.box.h / cellH))
  (rows, cols)

proc rpcPackUiAttachParams(cols, rows: int, opts: openArray[(string, bool)]): RpcParamsBuffer =
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

proc runWindyFigdrawGui*(config: GuiConfig) =
  when not defined(emscripten):
    setFigDataDir(getCurrentDir() / "deps" / "figdraw" / "data")

  app.running = true
  app.autoUiScale = false
  app.uiScale = 1.0
  app.pixelScale = 1.0

  let typefaceId = getTypefaceImpl(config.fontTypeface)
  let monoFont = UiFont(
    typefaceId: typefaceId,
    size: config.fontSize,
    lineHeightScale: config.lineHeightScale,
  )
  let (cellW, cellH) = monoMetrics(monoFont)

  var frame = AppFrame(windowTitle: config.windowTitle)
  frame.windowInfo = WindowInfo(
    box: rect(0, 0, 1000, 700),
    running: true,
    focused: true,
    minimized: false,
    fullscreen: false,
    pixelRatio: 1.0,
  )

  let window = newWindyWindow(frame)
  window.runeInputEnabled = true

  let renderer =
    glrenderer.newFigRenderer(atlasSize = 2048, pixelScale = app.pixelScale)

  var client = newNeovimClient()
  client.start(config.nvimCmd, config.nvimArgs)
  discard client.discoverMetadata()

  var hl = HlState(attrs: initTable[int64, HlAttr]())

  var winInfo = window.getWindowInfo()
  var (rows, cols) = computeGridSize(winInfo, cellW, cellH)
  var state = initLineGridState(rows, cols)

  client.onNotification = proc(methodName: string, params: RpcParamsBuffer) =
    if methodName == "redraw":
      handleRedraw(state, hl, params)

  block attachUi:
    let opts = [
      ("rgb", true),
      ("ext_linegrid", true),
      ("ext_hlstate", true),
    ]
    discard client.callAndWait("nvim_ui_attach", rpcPackUiAttachParams(cols, rows, opts), timeout = 3.0)

  proc redraw() =
    winInfo = window.getWindowInfo()
    var renders = makeRenderTree(float32(winInfo.box.w), float32(winInfo.box.h), monoFont, state, cellW, cellH)
    renderer.renderFrame(renders, winInfo.box.wh.scaled())
    when not UseMetalBackend:
      window.swapBuffers()

  proc tryResizeUi() =
    winInfo = window.getWindowInfo()
    let newSz = computeGridSize(winInfo, cellW, cellH)
    if newSz.rows != state.rows or newSz.cols != state.cols:
      discard client.request("nvim_ui_try_resize", rpcPackParams(newSz.cols, newSz.rows))

  window.onCloseRequest = proc() =
    app.running = false
  window.onResize = proc() =
    tryResizeUi()
    state.needsRedraw = true

  window.onRune = proc(r: Rune) =
    let s = $r
    discard client.request("nvim_input", rpcPackParams(s))

  window.onButtonPress = proc(button: Button) =
    let input = keyToNvimInput(button)
    if input.len > 0:
      discard client.request("nvim_input", rpcPackParams(input))

  try:
    while app.running:
      pollEvents()
      client.poll()
      if state.needsRedraw:
        redraw()
        state.needsRedraw = false
      when not defined(emscripten):
        sleep(8)
  finally:
    when not defined(emscripten):
      window.close()
    client.stop()

when isMainModule:
  runWindyFigdrawGui(
    GuiConfig(
      nvimCmd: "nvim",
      nvimArgs: @[],
      windowTitle: "neonim (windy + figdraw)",
      fontTypeface: "HackNerdFont-Regular.ttf",
      fontSize: 16.0'f32,
      lineHeightScale: 1.0,
    )
  )
