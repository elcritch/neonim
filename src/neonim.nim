## Neonim - Neovim GUI backend in Nim.
##
import std/[streams, os, osproc, strutils, times, unicode]
import chronicles

import vmath
import msgpack4nim
import pkg/pixie
import siwin/[clipboards, colorutils]
import figdraw/windowing/siwinshim as siwin

import figdraw/[commons, fignodes, figrender]
import ./neonim/[types, rpc, nvim_client, ui_linegrid, gui_backend]

const
  EmbeddedWindowIconPng = staticRead("../data/neonim-icon-128.png")
  NeonimWindowBackendName = "siwin"

type GuiRuntime* = ref object
  config*: GuiConfig
  testCfg*: GuiTestConfig
  appRunning*: bool
  testStart*: float
  testSent*: bool
  testPassed*: bool
  figNodesDumpPath*: string
  window*: siwin.Window
  renderer*: FigRenderer[siwin.SiwinRenderBackend]
  windowStarted: bool
  mouseDown: MouseButtonView
  modifiers: ModifierView
  lastScroll: Vec2
  client*: NeovimClient
  monoFont*: FigFont
  cellW*: float32
  cellH*: float32
  scrollSpeedMultiplier*: float32
  iconRetriedAfterFirstStep: bool
  state*: LineGridState
  hl*: HlState
  frameIdle*: int

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
  runtime.renderer.beginFrame()
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
  runtime.renderer.endFrame()

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

proc rpcErrorText(buf: RpcParamsBuffer): string =
  if buf.isNilValue:
    return ""
  try:
    var text = ""
    rpcUnpack(buf, text)
    return text
  except CatchableError:
    return "<non-string rpc error>"

proc unpackStringOrBin(s: MsgStream): string =
  if s.is_string():
    let len = s.unpack_string()
    if len < 0:
      return ""
    return s.readExactStr(len)
  if s.is_bin():
    let len = s.unpack_bin()
    return s.readExactStr(len)
  ""

proc currentNvimMode(runtime: GuiRuntime): string =
  if not runtime.client.isRunning():
    return ""
  try:
    let resp =
      runtime.client.callAndWait("nvim_get_mode", rpcPackParams(), timeout = 0.75)
    if not resp.error.isNilValue:
      warn "nvim_get_mode failed", error = rpcErrorText(resp.error)
      return ""
    var s = MsgStream.init(resp.result.buf.data)
    s.setPosition(0)
    if not s.is_map():
      return ""
    let mapLen = s.unpack_map()
    for _ in 0 ..< mapLen:
      if not (s.is_string() or s.is_bin()):
        s.skip_msg()
        s.skip_msg()
        continue
      let key = unpackStringOrBin(s)
      if key == "mode":
        if s.is_string() or s.is_bin():
          return unpackStringOrBin(s)
        s.skip_msg()
      else:
        s.skip_msg()
  except CatchableError as err:
    warn "failed to read nvim mode", error = err.msg
  ""

proc copyVisualSelectionToClipboard(runtime: GuiRuntime): bool =
  let mode = runtime.currentNvimMode()
  if not isVisualLikeMode(mode):
    return false
  try:
    let yankResp =
      runtime.client.callAndWait("nvim_input", rpcPackParams("y"), timeout = 0.75)
    if not yankResp.error.isNilValue:
      warn "nvim yank failed", error = rpcErrorText(yankResp.error)
      return false

    let regResp = runtime.client.callAndWait(
      "nvim_eval", rpcPackParams("getreg('\"')"), timeout = 0.75
    )
    if not regResp.error.isNilValue:
      warn "nvim getreg failed", error = rpcErrorText(regResp.error)
      return false

    var copiedText = ""
    rpcUnpack(regResp.result, copiedText)
    if not runtime.window.isNil:
      runtime.window.clipboard.text = copiedText
    return true
  except CatchableError as err:
    warn "copy shortcut failed", error = err.msg
    return false

proc pasteClipboard(runtime: GuiRuntime): bool =
  try:
    if runtime.window.isNil:
      return false
    let clipboardText = runtime.window.clipboard.text()
    if clipboardText.len == 0:
      return true
    return runtime.safeRequest("nvim_paste", rpcPackParams(clipboardText, false, -1))
  except CatchableError as err:
    warn "paste shortcut failed", error = err.msg
    return false

proc handleCmdShortcut(runtime: GuiRuntime, key: siwin.Key): bool =
  case cmdShortcutAction(key)
  of csaCopy:
    runtime.state.clearPanelHighlight()
    discard runtime.copyVisualSelectionToClipboard()
    true
  of csaPaste:
    runtime.state.clearPanelHighlight()
    discard runtime.pasteClipboard()
    true
  of csaNone:
    false

proc tryResizeUi*(runtime: GuiRuntime)
proc adjustUiScale(runtime: GuiRuntime, delta: float32): bool

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

proc formatModifierSet(modifiers: ModifierView): string =
  if siwin.ModifierKey.shift in modifiers:
    result.add "S"
  if siwin.ModifierKey.control in modifiers:
    result.add "C"
  if siwin.ModifierKey.alt in modifiers:
    result.add "A"
  if siwin.ModifierKey.system in modifiers:
    result.add "D"
  if siwin.ModifierKey.capsLock in modifiers:
    result.add "Caps"
  if siwin.ModifierKey.numLock in modifiers:
    result.add "Num"
  if result.len == 0:
    result = "-"

proc formatInputText(text: string): string =
  for r in text.runes:
    let code = int(r)
    if code >= 32 and code < 127:
      result.add char(code)
    else:
      result.add "\\u"
      result.add code.toHex(4)

proc setWindowIcon(window: siwin.Window, image: Image): bool =
  if window.isNil:
    return false
  if image.isNil or image.width <= 0 or image.height <= 0 or image.data.len == 0:
    window.icon = nil
    return false
  var pixelBuffer = PixelBuffer(
    data: image.data[0].addr,
    size: ivec2(image.width.int32, image.height.int32),
    format: PixelBufferFormat.rgbx_32bit,
  )
  window.icon = pixelBuffer
  true

proc trySetWindowIcon(window: siwin.Window) =
  try:
    if window.setWindowIcon(pixie.decodeImage(EmbeddedWindowIconPng)):
      return
    warn "failed to set embedded window icon", error = "decoded image was empty"
  except CatchableError as err:
    warn "failed to set embedded window icon", error = err.msg

  let iconPath = sourceDataDir() / "neonim-icon-128.png"
  if not fileExists(iconPath):
    warn "window icon not found", path = iconPath
    return
  try:
    if not window.setWindowIcon(pixie.readImage(iconPath)):
      warn "failed to set window icon", path = iconPath, error = "icon image was empty"
  except CatchableError as err:
    warn "failed to set window icon", path = iconPath, error = err.msg

proc mouseCell(runtime: GuiRuntime): tuple[row, col: int] =
  let mousePos = vec2(
      ivec2(runtime.window.mouse.pos.x.int32, runtime.window.mouse.pos.y.int32)
    )
    .descaled()
  result = mouseGridCell(
    mousePos, runtime.state.rows, runtime.state.cols, runtime.cellW, runtime.cellH
  )

proc sendMouseInput(runtime: GuiRuntime, button, action: string, row, col: int): bool =
  if button.len == 0:
    return false
  let mods = mouseModifierFlags(runtime.modifiers)
  runtime.state.setPanelHighlight(row, col)
  result = runtime.safeRequest(
    "nvim_input_mouse", rpcPackParams(button, action, mods, 0, row, col)
  )

proc handleMouseButton(
    runtime: GuiRuntime, button: siwin.MouseButton, action: string
): bool =
  let mouseButton = mouseButtonToNvimButton(button)
  if mouseButton.len == 0:
    return false
  let cell = runtime.mouseCell()
  discard runtime.sendMouseInput(mouseButton, action, cell.row, cell.col)
  result = true

proc handleMouseMultiClick(runtime: GuiRuntime, clickCount: int): bool =
  let cell = runtime.mouseCell()
  let multiInput = multiClickToNvimInput(clickCount, cell.row, cell.col)
  if multiInput.len == 0:
    return false
  runtime.state.setPanelHighlight(cell.row, cell.col)
  result = runtime.safeRequest("nvim_input", rpcPackParams(multiInput))

proc handleKeyPress(runtime: GuiRuntime, key: siwin.Key, modifiers: ModifierView) =
  runtime.state.clearCommittedCmdline()
  let ctrlDown = siwin.ModifierKey.control in modifiers
  let shiftDown = siwin.ModifierKey.shift in modifiers
  let altDown = siwin.ModifierKey.alt in modifiers
  let cmdDown = siwin.ModifierKey.system in modifiers
  let uiDelta = uiScaleDeltaForShortcut(key, modifiers)
  if uiDelta != 0.0'f32:
    runtime.state.clearPanelHighlight()
    discard runtime.adjustUiScale(uiDelta)
    return
  if cmdDown and runtime.handleCmdShortcut(key):
    return
  runtime.state.clearPanelHighlight()
  if key == siwin.Key.enter and runtime.state.cmdlineActive:
    runtime.state.cmdlineCommitPending = true
  if key == siwin.Key.escape:
    runtime.state.cmdlineCommitPending = false
    runtime.state.cmdlineCommittedText = ""
  let input = keyToNvimInput(key, ctrlDown, altDown, shiftDown)
  info "input key mapped",
    key = $key, modifiers = formatModifierSet(modifiers), mapped = input
  if input.len > 0:
    discard runtime.safeRequest("nvim_input", rpcPackParams(input))

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
  when not defined(emscripten):
    sleep(8)
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

proc pollWindowEvents(runtime: GuiRuntime) =
  if runtime.window.isNil:
    return
  if not runtime.windowStarted:
    runtime.window.firstStep(makeVisible = true)
    runtime.windowStarted = true
  if runtime.window.opened:
    runtime.window.step()

proc stepGui*(runtime: GuiRuntime): bool =
  runtime.pollWindowEvents()
  if not runtime.iconRetriedAfterFirstStep:
    trySetWindowIcon(runtime.window)
    runtime.iconRetriedAfterFirstStep = true
  runtime.client.poll()
  if not runtime.client.isRunning():
    runtime.appRunning = false
    return false
  runtime.handleGuiTest()
  var didRedraw = false
  if runtime.state.needsRedraw:
    runtime.redrawGui()
    runtime.state.needsRedraw = false
    didRedraw = true
    runtime.frameIdle = 0
  when not defined(emscripten):
    if not didRedraw:
      runtime.frameIdle = min(runtime.frameIdle + 1, 1024)
      #if runtime.frameIdle mod 8 == 0:
      #  echo "sleep time: ", (runtime.frameIdle div 8), " idle: ", runtime.frameIdle
      sleep(runtime.frameIdle div 8)
  result = runtime.appRunning

proc shutdownGui*(runtime: GuiRuntime) =
  when not defined(emscripten):
    runtime.window.close()
  runtime.client.stop()

proc scrollSpeedMultiplierFromEnv*(): float32 =
  const EnvKey = "NEONIM_SCROLL_SPEED_MULTIPLIER"
  let raw = getEnv(EnvKey)
  if raw.len == 0:
    return DefaultMouseScrollSpeedMultiplier
  try:
    let parsed = raw.parseFloat().float32
    if parsed > 0:
      return parsed
    warn "invalid scroll speed multiplier, must be > 0", env = EnvKey, value = raw
  except ValueError:
    warn "invalid scroll speed multiplier, must be numeric", env = EnvKey, value = raw
  DefaultMouseScrollSpeedMultiplier

proc initGuiRuntime*(
    config: GuiConfig, testCfg: GuiTestConfig = GuiTestConfig()
): GuiRuntime =
  #let dataDir = resolveDataDir(config.fontTypeface)
  #when not defined(emscripten):
  #setFigDataDir(dataDir)

  new(result)
  result.config = config
  result.testCfg = testCfg
  result.appRunning = true
  result.scrollSpeedMultiplier = scrollSpeedMultiplierFromEnv()
  result.testStart = epochTime()
  result.figNodesDumpPath = getEnv("NEONIM_FIG_NODES_OUT")
  let size = ivec2(1000, 700)
  let title = "Neonim"
  let typefaceId = loadTypeface(config.fontTypeface, [config.defaultTypeface])
  result.monoFont = FigFont(typefaceId: typefaceId, size: config.fontSize)
  result.window = siwin.newSiwinWindow(size = size, fullscreen = false, title = title)
  result.mouseDown = {}
  result.modifiers = {}
  result.lastScroll = vec2(0, 0)
  trySetWindowIcon(result.window)

  if getEnv("HDI") != "":
    setFigUiScale getEnv("HDI").parseFloat()
  else:
    setFigUiScale result.window.contentScale()
  if size != size.scaled():
    result.window.size = size.scaled()

  result.renderer =
    newFigRenderer(atlasSize = 4096, backendState = siwin.SiwinRenderBackend())
  result.renderer.setupBackend(result.window)

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

  runtime.window.eventsHandler.onClose = proc(_: siwin.CloseEvent) =
    runtime.appRunning = false
  runtime.window.eventsHandler.onResize = proc(_: siwin.ResizeEvent) =
    runtime.tryResizeUi()
    runtime.state.needsRedraw = true

  runtime.window.eventsHandler.onMouseMove = proc(_: siwin.MouseMoveEvent) =
    let dragButton = mouseDragButtonToNvimButton(runtime.mouseDown)
    if dragButton.len == 0:
      return
    let cell = runtime.mouseCell()
    discard runtime.sendMouseInput(dragButton, "drag", cell.row, cell.col)

  runtime.window.eventsHandler.onScroll = proc(e: siwin.ScrollEvent) =
    runtime.lastScroll = vec2(e.deltaX.float32, e.delta.float32)
    let actions = mouseScrollActions(runtime.lastScroll, runtime.scrollSpeedMultiplier)
    if actions.len == 0:
      return
    let cell = runtime.mouseCell()
    for action in actions:
      discard runtime.sendMouseInput("wheel", action, cell.row, cell.col)

  runtime.window.eventsHandler.onTextInput = proc(e: siwin.TextInputEvent) =
    trace "input text event",
      text = formatInputText(e.text),
      modifiers = formatModifierSet(runtime.modifiers),
      repeated = e.repeated
    let ctrlDown = siwin.ModifierKey.control in runtime.modifiers
    let altDown = siwin.ModifierKey.alt in runtime.modifiers
    let cmdDown = siwin.ModifierKey.system in runtime.modifiers
    if ctrlDown:
      return
    if altDown:
      return
    if cmdDown:
      return
    runtime.state.clearPanelHighlight()
    runtime.state.clearCommittedCmdline()
    for r in e.text.runes:
      let code = int(r)
      # Some platforms emit control-code text for special keys (e.g. Up -> 0x1E).
      # Those keys are already handled by onKey, so ignore non-printable text input.
      if code < 32 or code == 127:
        continue
      let s = runeToNvimInput(r)
      discard runtime.safeRequest("nvim_input", rpcPackParams(s))

  runtime.window.eventsHandler.onKey = proc(e: siwin.KeyEvent) =
    runtime.modifiers = e.modifiers
    trace "input key event",
      key = $e.key,
      modifiers = formatModifierSet(e.modifiers),
      pressed = e.pressed,
      repeated = e.repeated,
      generated = e.generated
    if not e.pressed:
      return
    runtime.handleKeyPress(e.key, e.modifiers)

  runtime.window.eventsHandler.onMouseButton = proc(e: siwin.MouseButtonEvent) =
    if e.pressed:
      runtime.mouseDown.incl(e.button)
      discard runtime.handleMouseButton(e.button, "press")
    else:
      runtime.mouseDown.excl(e.button)
      discard runtime.handleMouseButton(e.button, "release")

  runtime.window.eventsHandler.onClick = proc(e: siwin.ClickEvent) =
    if e.double:
      discard runtime.handleMouseMultiClick(2)

proc runFigdrawGuiWithTest*(config: GuiConfig, testCfg: GuiTestConfig): bool =
  let runtime = initGuiRuntime(config, testCfg)
  try:
    while runtime.appRunning:
      discard runtime.stepGui()
  finally:
    runtime.shutdownGui()
  result = (not testCfg.enabled) or runtime.testPassed

proc runFigdrawGui*(config: GuiConfig) =
  discard runFigdrawGuiWithTest(config, GuiTestConfig())

proc parseLaunchArgs*(args: seq[string]): tuple[detach: bool, nvimArgs: seq[string]] =
  result.nvimArgs = @[]
  var passthroughOnly = false
  for arg in args:
    if passthroughOnly:
      result.nvimArgs.add(arg)
      continue
    if arg == "--":
      passthroughOnly = true
      result.nvimArgs.add(arg)
      continue
    if arg == "-D" or arg == "--detach":
      result.detach = true
      continue
    result.nvimArgs.add(arg)

proc launchDetached*(args: seq[string]) =
  let child = startProcess(getAppFilename(), args = args, options = {poDaemon})
  child.close()

proc guiConfigFromCli*(args: seq[string]): GuiConfig =
  let launch = parseLaunchArgs(args)
  registerStaticTypeface(
    "HackNerdFont-Regular.ttf", ".." / "data" / "HackNerdFont-Regular.ttf"
  )

  result = GuiConfig(
    nvimCmd: "nvim",
    nvimArgs: launch.nvimArgs,
    windowTitle: "neonim (" & NeonimWindowBackendName & " + figdraw)",
    fontTypeface: getEnv("FONT", "HackNerdFont-Regular.ttf"),
    defaultTypeface: "HackNerdFont-Regular.ttf",
    fontSize: 16.0'f32,
  )

when isMainModule:
  let launch = parseLaunchArgs(commandLineParams())
  if launch.detach:
    try:
      launchDetached(launch.nvimArgs)
      quit(0)
    except CatchableError as err:
      stderr.writeLine("neonim: failed to detach: ", err.msg)
      quit(1)
  runFigdrawGui(guiConfigFromCli(launch.nvimArgs))
