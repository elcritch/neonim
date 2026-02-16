## Neonim - Neovim GUI backend in Nim.
##
import std/[streams, os, osproc, strutils, times, unicode]
import chronicles

import vmath
import msgpack4nim
import pkg/pixie
import ./neonim/windowing_backend

import figdraw/[commons, fignodes, figrender]
import ./neonim/[types, rpc, nvim_client, ui_linegrid, gui_backend, modifier_state]

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
  renderer*: FigRenderer[NeonimRenderBackend]
  client*: NeovimClient
  monoFont*: FigFont
  cellW*: float32
  cellH*: float32
  scrollSpeedMultiplier*: float32
  iconRetriedAfterFirstStep: bool
  state*: LineGridState
  hl*: HlState

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
    setClipboardString(copiedText)
    return true
  except CatchableError as err:
    warn "copy shortcut failed", error = err.msg
    return false

proc pasteClipboard(runtime: GuiRuntime): bool =
  try:
    let clipboardText = getClipboardString()
    if clipboardText.len == 0:
      return true
    return runtime.safeRequest("nvim_paste", rpcPackParams(clipboardText, false, -1))
  except CatchableError as err:
    warn "paste shortcut failed", error = err.msg
    return false

proc handleCmdShortcut(runtime: GuiRuntime, button: Button): bool =
  case cmdShortcutAction(button)
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

proc trySetWindowIcon(window: Window) =
  try:
    window.icon = pixie.decodeImage(EmbeddedWindowIconPng)
    return
  except CatchableError as err:
    warn "failed to set embedded window icon", error = err.msg

  let iconPath = sourceDataDir() / "neonim-icon-128.png"
  if not fileExists(iconPath):
    warn "window icon not found", path = iconPath
    return
  try:
    window.icon = pixie.readImage(iconPath)
  except CatchableError as err:
    warn "failed to set window icon", path = iconPath, error = err.msg

proc mouseModifierFlagsFromState(ctrlDown, shiftDown, altDown, cmdDown: bool): string =
  if ctrlDown:
    result.add "C"
  if shiftDown:
    result.add "S"
  if altDown:
    result.add "A"
  if cmdDown:
    result.add "D"

proc mouseCell(runtime: GuiRuntime): tuple[row, col: int] =
  let mousePos = vec2(runtime.window.mousePos()).descaled()
  result = mouseGridCell(
    mousePos, runtime.state.rows, runtime.state.cols, runtime.cellW, runtime.cellH
  )

proc sendMouseInput(runtime: GuiRuntime, button, action: string, row, col: int): bool =
  if button.len == 0:
    return false
  let modsState = currentModifierState(runtime.window)
  let mods = mouseModifierFlagsFromState(
    modsState.ctrlDown, modsState.shiftDown, modsState.altDown, modsState.cmdDown
  )
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
  pollWindowEvents(runtime.window)
  if not runtime.iconRetriedAfterFirstStep:
    trySetWindowIcon(runtime.window)
    runtime.iconRetriedAfterFirstStep = true
  runtime.client.poll()
  if not runtime.client.isRunning():
    runtime.appRunning = false
    return false
  runtime.handleGuiTest()
  if runtime.state.needsRedraw:
    runtime.redrawGui()
    runtime.state.needsRedraw = false
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
  result.window = newNeonimWindow(size = size, fullscreen = false, title = title)
  trySetWindowIcon(result.window)
  result.window.runeInputEnabled = true

  if getEnv("HDI") != "":
    setFigUiScale getEnv("HDI").parseFloat()
  else:
    setFigUiScale result.window.contentScale()
  if size != size.scaled():
    result.window.size = size.scaled()

  result.renderer =
    newFigRenderer(atlasSize = 4096, backendState = NeonimRenderBackend())
  result.renderer.setupBackend(result.window.backendWindow())

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
    let actions =
      mouseScrollActions(runtime.window.scrollDelta(), runtime.scrollSpeedMultiplier)
    if actions.len == 0:
      return
    let cell = runtime.mouseCell()
    for action in actions:
      discard runtime.sendMouseInput("wheel", action, cell.row, cell.col)

  runtime.window.onRune = proc(r: Rune) =
    let mods = currentModifierState(runtime.window)
    if mods.ctrlDown:
      return
    if mods.altDown:
      return
    if mods.cmdDown:
      return
    runtime.state.clearPanelHighlight()
    runtime.state.clearCommittedCmdline()
    let s = runeToNvimInput(r)
    discard runtime.safeRequest("nvim_input", rpcPackParams(s))

  runtime.window.onButtonPress = proc(button: Button) =
    if runtime.handleMouseButton(button, "press"):
      return
    runtime.state.clearCommittedCmdline()
    let mods = currentModifierState(runtime.window)
    var shortcutMods: set[Button] = {}
    if mods.cmdDown:
      shortcutMods.incl KeyLeftSuper
    if mods.shiftDown:
      shortcutMods.incl KeyLeftShift
    let uiDelta = uiScaleDeltaForShortcut(button, ButtonView(shortcutMods))
    if uiDelta != 0.0'f32:
      runtime.state.clearPanelHighlight()
      discard runtime.adjustUiScale(uiDelta)
      return
    if mods.cmdDown and runtime.handleCmdShortcut(button):
      return
    runtime.state.clearPanelHighlight()
    if button == KeyEnter and runtime.state.cmdlineActive:
      runtime.state.cmdlineCommitPending = true
    if button == KeyEscape:
      runtime.state.cmdlineCommitPending = false
      runtime.state.cmdlineCommittedText = ""
    let input = keyToNvimInput(button, mods.ctrlDown, mods.altDown, mods.shiftDown)
    if input.len > 0:
      discard runtime.safeRequest("nvim_input", rpcPackParams(input))

  runtime.window.onButtonRelease = proc(button: Button) =
    discard runtime.handleMouseButton(button, "release")

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
