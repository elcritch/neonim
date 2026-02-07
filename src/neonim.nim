## Neonim - Neovim GUI backend in Nim.
##
import std/[streams, os, strutils, times]
import chronicles

import vmath
import msgpack4nim
import pkg/pixie
when defined(macosx):
  import windy/platforms/macos/macdefs

import figdraw/[commons, fignodes, figrender, windyshim]
import ./neonim/[types, rpc, nvim_client, ui_linegrid, gui_backend]

const EmbeddedWindowIconPng = staticRead("../data/neonim-icon-128.png")

type GuiRuntime* = ref object
  config*: GuiConfig
  testCfg*: GuiTestConfig
  appRunning*: bool
  testStart*: float
  testSent*: bool
  testPassed*: bool
  figNodesDumpPath*: string
  window*: Window
  renderer*: FigRenderer[WindyRenderBackend]
  client*: NeovimClient
  monoFont*: FigFont
  cellW*: float32
  cellH*: float32
  state*: LineGridState
  hl*: HlState
  when UseMetalBackend:
    metalHandle*: MetalLayerHandle

proc computeGridSize(size: Vec2, cellW, cellH: float32): tuple[rows, cols: int] =
  let cols = max(1, int(size.x / cellW))
  let rows = max(1, int(size.y / cellH / 2))
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

proc dumpFigNodes*(
    renders: Renders,
    path: string,
    logicalSize: Vec2,
    physicalSize: Vec2,
    uiScale: float32,
    contentScale: float32,
) =
  if path.len == 0:
    return
  var dump = newStringOfCap(4096)
  dump.add("frame logical ")
  dump.add($logicalSize.x)
  dump.add(" ")
  dump.add($logicalSize.y)
  dump.add(" physical ")
  dump.add($physicalSize.x)
  dump.add(" ")
  dump.add($physicalSize.y)
  dump.add(" ui_scale ")
  dump.add($uiScale)
  dump.add(" content_scale ")
  dump.add($contentScale)
  dump.add("\n")
  for layer, list in renders.layers:
    dump.add("layer ")
    dump.add($int(layer))
    dump.add(" nodes=")
    dump.add($list.nodes.len)
    dump.add("\n")
    for idx, node in list.nodes:
      dump.add("  idx=")
      dump.add($idx)
      dump.add(" kind=")
      dump.add($node.kind)
      dump.add(" parent=")
      dump.add($node.parent.int)
      dump.add(" children=")
      dump.add($node.childCount)
      dump.add(" box=(")
      dump.add($node.screenBox.x)
      dump.add(", ")
      dump.add($node.screenBox.y)
      dump.add(", ")
      dump.add($node.screenBox.w)
      dump.add(", ")
      dump.add($node.screenBox.h)
      dump.add(")")
      if node.kind == nkText:
        var text = ""
        var count = 0
        for r in node.textLayout.runes:
          if count >= 200:
            text.add("...")
            break
          let code = int(r)
          if code >= 32 and code < 127:
            text.add(char(code))
          else:
            text.add("\\u")
            text.add(code.toHex(4))
          inc count
        dump.add("\n         text=\"")
        dump.add(text)
        dump.add("\"")
      dump.add("\n")
  writeFile(path, dump)

proc redrawGui*(runtime: GuiRuntime) =
  when UseMetalBackend:
    runtime.metalHandle.updateMetalLayer(runtime.window)
  let sz = runtime.window.logicalSize()
  let phys = vec2(runtime.window.size())
  var renders = makeRenderTree(
    sz.x, sz.y, runtime.monoFont, runtime.state, runtime.hl, runtime.cellW,
    runtime.cellH,
  )
  dumpFigNodes(
    renders,
    runtime.figNodesDumpPath,
    sz,
    phys,
    figUiScale(),
    runtime.window.contentScale(),
  )
  runtime.renderer.renderFrame(renders, sz)
  when not UseMetalBackend:
    runtime.window.swapBuffers()

proc safeRequest(
    runtime: GuiRuntime, methodName: string, params: RpcParamsBuffer
): bool =
  if not runtime.client.isRunning():
    runtime.appRunning = false
    return false
  try:
    discard runtime.client.request(methodName, params)
    return true
  except CatchableError as err:
    warn "nvim request failed", rpcMethod = methodName, error = err.msg
    runtime.appRunning = false
    return false

proc tryResizeUi*(runtime: GuiRuntime)

proc resolveDataDir(fontTypeface: string): string =
  let appDir = getAppDir()
  let candidates =
    @[
      normalizedPath(appDir / ".." / "data"),
      normalizedPath(appDir / "data"),
      normalizedPath(getCurrentDir() / "data"),
    ]
  for dir in candidates:
    if fileExists(dir / fontTypeface):
      return dir
  result = candidates[0]

proc sourceDataDir(): string =
  normalizedPath(parentDir(currentSourcePath()) / ".." / "data")

when defined(macosx):
  objc:
    proc setApplicationIconImage(self: NSApplication, x: NSImage)

  proc trySetMacAppIcon(iconBytes: string, source = "embedded") =
    try:
      if iconBytes.len == 0:
        warn "empty macOS app icon bytes", source = source
        return
      autoreleasepool:
        let data =
          NSData.dataWithBytes(cast[pointer](unsafeAddr iconBytes[0]), iconBytes.len)
        let image = NSImage.alloc().initWithData(data)
        if image.int == 0:
          warn "failed to decode macOS app icon image", source = source
          return
        NSApp.setApplicationIconImage(image)
    except CatchableError as err:
      warn "failed to set macOS app icon", source = source, error = err.msg

proc trySetWindowIcon(window: Window) =
  try:
    window.icon = pixie.decodeImage(EmbeddedWindowIconPng)
    when defined(macosx):
      trySetMacAppIcon(EmbeddedWindowIconPng)
    return
  except CatchableError as err:
    warn "failed to set embedded window icon", error = err.msg

  let iconPath = sourceDataDir() / "neonim-icon-128.png"
  if not fileExists(iconPath):
    warn "window icon not found", path = iconPath
    return
  try:
    window.icon = pixie.readImage(iconPath)
    when defined(macosx):
      trySetMacAppIcon(readFile(iconPath), source = iconPath)
  except CatchableError as err:
    warn "failed to set window icon", path = iconPath, error = err.msg

proc mouseCell(runtime: GuiRuntime): tuple[row, col: int] =
  let mousePos = vec2(runtime.window.mousePos()).descaled()
  result = mouseGridCell(
    mousePos, runtime.state.rows, runtime.state.cols, runtime.cellW, runtime.cellH
  )

proc sendMouseInput(runtime: GuiRuntime, button, action: string, row, col: int): bool =
  if button.len == 0:
    return false
  let mods = mouseModifierFlags(runtime.window.buttonDown())
  runtime.state.setPanelHighlight(row, col)
  result = runtime.safeRequest(
    "nvim_input_mouse", rpcPackParams(button, action, mods, 0, row, col)
  )

proc handleMouseButton(runtime: GuiRuntime, button: Button, action: string): bool =
  let cell = runtime.mouseCell()
  if action == "press":
    let multiInput = multiClickToNvimInput(button, cell.row, cell.col)
    if multiInput.len > 0:
      runtime.state.setPanelHighlight(cell.row, cell.col)
      return runtime.safeRequest("nvim_input", rpcPackParams(multiInput))

  let mouseButton = mouseButtonToNvimButton(button)
  if mouseButton.len == 0:
    return false
  discard runtime.sendMouseInput(mouseButton, action, cell.row, cell.col)
  result = true

proc adjustUiScale(runtime: GuiRuntime, delta: float32): bool =
  if delta == 0.0'f32:
    return false
  let current = figUiScale()
  let next = min(UiScaleMax, max(UiScaleMin, current + delta))
  if abs(next - current) < 0.0001'f32:
    return false
  setFigUiScale(next)
  let (cellW, cellH) = monoMetrics(runtime.monoFont)
  runtime.cellW = cellW
  runtime.cellH = cellH
  runtime.tryResizeUi()
  runtime.state.needsRedraw = true
  info "ui scale", previous = current, current = next, cellW = cellW, cellH = cellH
  result = true

proc tryResizeUi*(runtime: GuiRuntime) =
  let sz = runtime.window.logicalSize()
  let newSz = computeGridSize(sz, runtime.cellW, runtime.cellH)
  if newSz.rows != runtime.state.rows or newSz.cols != runtime.state.cols:
    discard
      runtime.safeRequest("nvim_ui_try_resize", rpcPackParams(newSz.cols, newSz.rows))

proc handleGuiTest*(runtime: GuiRuntime) =
  let cfg = runtime.testCfg
  if not cfg.enabled:
    return
  if not runtime.testSent and cfg.input.len > 0 and
      (epochTime() - runtime.testStart) > 0.1:
    discard runtime.safeRequest("nvim_input", rpcPackParams(cfg.input))
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
  if not runtime.client.isRunning():
    runtime.appRunning = false
    return false
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
  let dataDir = resolveDataDir(config.fontTypeface)
  when not defined(emscripten):
    setFigDataDir(dataDir)

  new(result)
  result.config = config
  result.testCfg = testCfg
  result.appRunning = true
  result.testStart = epochTime()
  result.figNodesDumpPath = getEnv("NEONIM_FIG_NODES_OUT")
  let size = ivec2(1000, 700)
  let title = "Neonim"
  let typefaceId = loadTypeface(config.fontTypeface)
  result.monoFont = FigFont(typefaceId: typefaceId, size: config.fontSize)
  result.window = newWindyWindow(size = size, fullscreen = false, title = title)
  trySetWindowIcon(result.window)
  result.window.runeInputEnabled = true

  if getEnv("HDI") != "":
    setFigUiScale getEnv("HDI").parseFloat()
  else:
    setFigUiScale result.window.contentScale()
  if size != size.scaled():
    result.window.size = size.scaled()

  result.renderer =
    newFigRenderer(atlasSize = 4096, backendState = WindyRenderBackend())
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
  warn "mono metrics: ", cellW = cellW, cellH = cellH

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

  runtime.window.onMouseMove = proc() =
    let dragButton = mouseDragButtonToNvimButton(runtime.window.buttonDown())
    if dragButton.len == 0:
      return
    let cell = runtime.mouseCell()
    discard runtime.sendMouseInput(dragButton, "drag", cell.row, cell.col)

  runtime.window.onScroll = proc() =
    let actions = mouseScrollActions(runtime.window.scrollDelta())
    if actions.len == 0:
      return
    let cell = runtime.mouseCell()
    for action in actions:
      discard runtime.sendMouseInput("wheel", action, cell.row, cell.col)

  runtime.window.onRune = proc(r: Rune) =
    let buttons = runtime.window.buttonDown()
    if buttons[KeyLeftControl] or buttons[KeyRightControl]:
      return
    if buttons[KeyLeftAlt] or buttons[KeyRightAlt]:
      return
    runtime.state.clearPanelHighlight()
    runtime.state.clearCommittedCmdline()
    let s = $r
    discard runtime.safeRequest("nvim_input", rpcPackParams(s))

  runtime.window.onButtonPress = proc(button: Button) =
    if runtime.handleMouseButton(button, "press"):
      return
    runtime.state.clearCommittedCmdline()
    let buttons = runtime.window.buttonDown()
    let uiDelta = uiScaleDeltaForShortcut(button, buttons)
    if uiDelta != 0.0'f32:
      runtime.state.clearPanelHighlight()
      discard runtime.adjustUiScale(uiDelta)
      return
    runtime.state.clearPanelHighlight()
    if button == KeyEnter and runtime.state.cmdlineActive:
      runtime.state.cmdlineCommitPending = true
    if button == KeyEscape:
      runtime.state.cmdlineCommitPending = false
      runtime.state.cmdlineCommittedText = ""
    let ctrlDown = buttons[KeyLeftControl] or buttons[KeyRightControl]
    let altDown = buttons[KeyLeftAlt] or buttons[KeyRightAlt]
    let shiftDown = buttons[KeyLeftShift] or buttons[KeyRightShift]
    let input = keyToNvimInput(button, ctrlDown, altDown, shiftDown)
    if input.len > 0:
      discard runtime.safeRequest("nvim_input", rpcPackParams(input))

  runtime.window.onButtonRelease = proc(button: Button) =
    discard runtime.handleMouseButton(button, "release")

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

proc guiConfigFromCli*(args: seq[string]): GuiConfig =
  result = GuiConfig(
    nvimCmd: "nvim",
    nvimArgs: args,
    windowTitle: "neonim (windy + figdraw)",
    fontTypeface: "HackNerdFont-Regular.ttf",
    fontSize: 16.0'f32,
  )

when isMainModule:
  runWindyFigdrawGui(guiConfigFromCli(commandLineParams()))
