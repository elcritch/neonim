## Neonim - Neovim GUI backend in Nim.
##
import std/[streams, os, strutils, times]

import vmath
import msgpack4nim

import figdraw/[commons, fignodes, figrender, windyshim]
import ./neonim/[types, rpc, nvim_client, ui_linegrid, gui_backend]

type GuiRuntime* = ref object
  config*: GuiConfig
  testCfg*: GuiTestConfig
  appRunning*: bool
  testStart*: float
  testSent*: bool
  testPassed*: bool
  window*: Window
  renderer*: FigRenderer
  client*: NeovimClient
  monoFont*: UiFont
  cellW*: float32
  cellH*: float32
  state*: LineGridState
  hl*: HlState
  when UseMetalBackend:
    metalHandle*: MetalLayerHandle

proc computeGridSize(size: Vec2, cellW, cellH: float32): tuple[rows, cols: int] =
  let cols = max(1, int(size.x / cellW))
  let rows = max(1, int(size.y / cellH))
  (rows, cols)

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

proc redrawGui*(runtime: GuiRuntime) =
  when UseMetalBackend:
    runtime.metalHandle.updateMetalLayer(runtime.window)
  let sz = runtime.window.logicalSize()
  var renders = makeRenderTree(
    sz.x, sz.y, runtime.monoFont, runtime.state, runtime.cellW, runtime.cellH
  )
  runtime.renderer.renderFrame(renders, sz)
  when not UseMetalBackend:
    runtime.window.swapBuffers()

proc tryResizeUi*(runtime: GuiRuntime) =
  let sz = runtime.window.logicalSize()
  let newSz = computeGridSize(sz, runtime.cellW, runtime.cellH)
  if newSz.rows != runtime.state.rows or newSz.cols != runtime.state.cols:
    discard runtime.client.request(
      "nvim_ui_try_resize", rpcPackParams(newSz.cols, newSz.rows)
    )

proc handleGuiTest*(runtime: GuiRuntime) =
  let cfg = runtime.testCfg
  if not cfg.enabled:
    return
  if not runtime.testSent and cfg.input.len > 0 and
      (epochTime() - runtime.testStart) > 0.1:
    discard runtime.client.request("nvim_input", rpcPackParams(cfg.input))
    runtime.testSent = true
  if not runtime.testPassed and cfg.expectCmdlinePrefix.len > 0:
    if runtime.state.cmdlineActive and
        runtime.state.cmdlineText.startsWith(cfg.expectCmdlinePrefix):
      runtime.testPassed = true
      runtime.appRunning = false
  if cfg.timeoutSeconds > 0 and (epochTime() - runtime.testStart) > cfg.timeoutSeconds:
    runtime.appRunning = false

proc stepGui*(runtime: GuiRuntime): bool =
  pollEvents()
  runtime.client.poll()
  runtime.handleGuiTest()
  if runtime.state.needsRedraw:
    runtime.redrawGui()
    runtime.state.needsRedraw = false
  when not defined(emscripten):
    sleep(8)
  result = runtime.appRunning

proc shutdownGui*(runtime: GuiRuntime) =
  when not defined(emscripten):
    runtime.window.close()
  runtime.client.stop()

proc initGuiRuntime*(
    config: GuiConfig, testCfg: GuiTestConfig = GuiTestConfig()
): GuiRuntime =
  when not defined(emscripten):
    setFigDataDir(getCurrentDir() / "data")

  new(result)
  result.config = config
  result.testCfg = testCfg
  result.appRunning = true
  result.testStart = epochTime()
  let size = ivec2(1000, 700)
  let title = "Neonim"
  let typefaceId = loadTypeface(config.fontTypeface)
  result.monoFont = UiFont(typefaceId: typefaceId, size: config.fontSize)
  result.window = newWindyWindow(size = size, fullscreen = false, title = title)
  result.window.runeInputEnabled = true

  if getEnv("HDI") != "":
    setFigUiScale getEnv("HDI").parseFloat()
  else:
    setFigUiScale result.window.contentScale()
  if size != size.scaled():
    result.window.size = size.scaled()

  result.renderer = newFigRenderer(atlasSize = 2048)
  when UseMetalBackend:
    result.metalHandle =
      attachMetalLayer(result.window, result.renderer.ctx.metalDevice())
    result.renderer.ctx.presentLayer = result.metalHandle.layer

  result.client = newNeovimClient()
  result.client.start(config.nvimCmd, config.nvimArgs)
  discard result.client.discoverMetadata()

  result.hl = HlState(attrs: initTable[int64, HlAttr]())
  let sz = result.window.logicalSize()
  let (cellW, cellH) = monoMetrics(result.monoFont)
  result.cellW = cellW
  result.cellH = cellH

  var (rows, cols) = computeGridSize(sz, cellW, cellH)
  result.state = initLineGridState(rows, cols)

  let runtime = result
  runtime.client.onNotification = proc(methodName: string, params: RpcParamsBuffer) =
    if methodName == "redraw":
      handleRedraw(runtime.state, runtime.hl, params)

  block attachUi:
    let opts = [
      ("rgb", true),
      ("ext_linegrid", true),
      ("ext_hlstate", true),
      ("ext_cmdline", true),
      ("ext_wildmenu", true),
    ]
    discard runtime.client.callAndWait(
      "nvim_ui_attach", rpcPackUiAttachParams(cols, rows, opts), timeout = 3.0
    )

  runtime.window.onCloseRequest = proc() =
    runtime.appRunning = false
  runtime.window.onResize = proc() =
    runtime.tryResizeUi()
    runtime.state.needsRedraw = true

  runtime.window.onRune = proc(r: Rune) =
    let s = $r
    discard runtime.client.request("nvim_input", rpcPackParams(s))

  runtime.window.onButtonPress = proc(button: Button) =
    if button == KeyEnter and runtime.state.cmdlineActive:
      runtime.state.cmdlineCommitPending = true
    if button == KeyEscape:
      runtime.state.cmdlineCommitPending = false
      runtime.state.cmdlineCommittedText = ""
    let input = keyToNvimInput(button)
    if input.len > 0:
      discard runtime.client.request("nvim_input", rpcPackParams(input))

proc runWindyFigdrawGuiWithTest*(config: GuiConfig, testCfg: GuiTestConfig): bool =
  let runtime = initGuiRuntime(config, testCfg)
  try:
    while runtime.appRunning:
      discard runtime.stepGui()
  finally:
    runtime.shutdownGui()
  result = (not testCfg.enabled) or runtime.testPassed

proc runWindyFigdrawGui*(config: GuiConfig) =
  discard runWindyFigdrawGuiWithTest(config, GuiTestConfig())

when isMainModule:
  runWindyFigdrawGui(
    GuiConfig(
      nvimCmd: "nvim",
      nvimArgs: @[],
      windowTitle: "neonim (windy + figdraw)",
      fontTypeface: "HackNerdFont-Regular.ttf",
      fontSize: 16.0'f32,
    )
  )
