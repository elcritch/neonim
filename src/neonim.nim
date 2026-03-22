## Neonim - Neovim GUI backend in Nim.
##
import std/[streams, os, osproc, strutils, times, unicode, tables]
import chronicles

import libbacktrace

import vmath
import msgpack4nim
import pkg/pixie
import siwin/[clipboards, colorutils]
import figdraw/windowing/siwinshim as siwin

import figdraw/[commons, fignodes, figrender]
import figdraw/common/fonttypes
import ./neonim/[types, rpc, nvim_client, ui_linegrid, gui_backend]

const
  EmbeddedWindowIconPng = staticRead("../data/neonim-icon-128.png")
  NeonimWindowBackendName = "siwin"
  DefaultFontSize = 16.0'f32
  TopBarHeight = 50.0'f32
  TopBarTabGap = 10.0'f32
  TopBarTabPadding = 18.0'f32
  TopBarTabMinWidth = 180.0'f32
  TopBarTabMaxWidth = 360.0'f32
  TopBarTabHeight = 36.0'f32
  TopBarTabY = 7.0'f32
  TopBarLeadingPad = 20.0'f32
  TopBarLeadingReserveMac = 150.0'f32
  TopBarNewTabWidth = 34.0'f32
  TopBarTextInset = 12.0'f32

type
  LineGridStateRef = ref LineGridState
  HlStateRef = ref HlState

  NvimProcessTab = ref object
    id: int
    mainDir: string
    label: string
    client: NeovimClient
    state: LineGridStateRef
    hl: HlStateRef

  GuiRuntime* = ref object
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
    tabs: seq[NvimProcessTab]
    activeTab: int
    nextTabId: int
    hoverTab: int
    hoverNewTab: bool
    topBarHeight: float32
    baseMainDir: string
    client*: NeovimClient
    monoFont*: FigFont
    cellW*: float32
    cellH*: float32
    scrollSpeedMultiplier*: float32
    scrollDirectionInverted*: bool
    iconRetriedAfterFirstStep: bool
    state*: LineGridStateRef
    hl*: HlStateRef
    frameIdle*: int

proc computeGridSize(size: Vec2, cellW, cellH: float32): tuple[rows, cols: int] =
  let cols = max(1, int(size.x / cellW))
  let rows = max(1, int(size.y / cellH / 2))
  (rows, cols)

proc contentLogicalSize(runtime: GuiRuntime): Vec2 =
  let sz = runtime.window.logicalSize()
  vec2(sz.x, max(1.0'f32, sz.y - runtime.topBarHeight))

proc runeCount(text: string): int =
  for _ in text.runes:
    inc result

proc homeShortPath(path: string): string =
  var normalized = normalizedPath(path)
  let homeDir = normalizedPath(getHomeDir())
  if homeDir.len > 0 and normalized.startsWith(homeDir):
    if normalized.len == homeDir.len:
      return "~"
    if normalized[homeDir.len] == DirSep:
      return "~" & normalized[homeDir.len .. ^1]
  normalized

proc guessMainDir(args: seq[string]): string =
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--":
      inc i
      break
    if arg.startsWith("-"):
      # Skip option values for common args that consume the next token.
      if arg in
          [
            "--cmd", "-c", "-S", "-u", "-i", "--listen", "--server", "-s", "-t", "-w",
            "-W",
          ] and i + 1 < args.len:
        inc i
      inc i
      continue
    let expanded = expandFilename(arg)
    if dirExists(expanded):
      return normalizedPath(expanded)
    if fileExists(expanded):
      return normalizedPath(parentDir(expanded))
    # For unsaved/new file paths, fall back to parent directory when provided.
    let parent = parentDir(expanded)
    if parent.len > 0 and parent != ".":
      return normalizedPath(parent)
    break

  while i < args.len:
    let arg = args[i]
    if arg.startsWith("-"):
      inc i
      continue
    let expanded = expandFilename(arg)
    if dirExists(expanded):
      return normalizedPath(expanded)
    if fileExists(expanded):
      return normalizedPath(parentDir(expanded))
    let parent = parentDir(expanded)
    if parent.len > 0 and parent != ".":
      return normalizedPath(parent)
    break
  normalizedPath(getCurrentDir())

proc tabLabelForDir(mainDir: string): string =
  let dirName = extractFilename(mainDir)
  let lead = if dirName.len > 0: dirName else: mainDir
  let shortPath = homeShortPath(mainDir)
  result = lead & " [" & shortPath & "]"

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

proc activeTabRef(runtime: GuiRuntime): NvimProcessTab =
  if runtime.tabs.len == 0:
    return nil
  if runtime.activeTab < 0 or runtime.activeTab >= runtime.tabs.len:
    runtime.activeTab = min(max(0, runtime.activeTab), runtime.tabs.len - 1)
  runtime.tabs[runtime.activeTab]

proc syncActiveAliases(runtime: GuiRuntime) =
  let tab = runtime.activeTabRef()
  if tab.isNil:
    runtime.client = nil
    runtime.state = nil
    runtime.hl = nil
    return
  runtime.client = tab.client
  runtime.state = tab.state
  runtime.hl = tab.hl

proc selectTab(runtime: GuiRuntime, idx: int): bool =
  if idx < 0 or idx >= runtime.tabs.len:
    return false
  runtime.activeTab = idx
  runtime.syncActiveAliases()
  if not runtime.state.isNil:
    runtime.state.needsRedraw = true
  result = true

proc normalizedExistingDir(path: string, fallbackDir: string): string =
  let candidate =
    if path.len > 0:
      expandFilename(path)
    else:
      ""
  if candidate.len > 0 and dirExists(candidate):
    return normalizedPath(candidate)
  result = normalizedPath(fallbackDir)

proc createProcessTab(
    runtime: GuiRuntime, mainDir: string, nvimArgs: seq[string]
): NvimProcessTab =
  let contentSz = runtime.contentLogicalSize()
  let (rows, cols) = computeGridSize(contentSz, runtime.cellW, runtime.cellH)
  let tabDir = normalizedExistingDir(mainDir, getCurrentDir())

  var stateRef: LineGridStateRef
  new(stateRef)
  stateRef[] = initLineGridState(rows, cols)

  var hlRef: HlStateRef
  new(hlRef)
  hlRef[] = HlState(attrs: initTable[int64, HlAttr]())

  let client = newNeovimClient()
  client.start(runtime.config.nvimCmd, nvimArgs, cwd = tabDir)
  discard client.discoverMetadata()

  let opts = [
    ("rgb", true),
    ("ext_linegrid", true),
    ("ext_hlstate", true),
    ("ext_cmdline", true),
    ("ext_wildmenu", true),
  ]
  discard client.callAndWait(
    "nvim_ui_attach", rpcPackUiAttachParams(cols, rows, opts), timeout = 3.0
  )

  let notifState = stateRef
  let notifHl = hlRef
  client.onNotification = proc(methodName: string, params: RpcParamsBuffer) =
    if methodName == "redraw":
      handleRedraw(notifState[], notifHl[], params)

  new(result)
  result.id = runtime.nextTabId
  inc runtime.nextTabId
  result.mainDir = tabDir
  result.label = tabLabelForDir(tabDir)
  result.client = client
  result.state = stateRef
  result.hl = hlRef

proc addProcessTab(
    runtime: GuiRuntime, mainDir: string, nvimArgs: seq[string] = @[]
): bool =
  try:
    runtime.tabs.add(runtime.createProcessTab(mainDir, nvimArgs))
    discard runtime.selectTab(runtime.tabs.len - 1)
    result = true
  except CatchableError as err:
    warn "failed to create nvim tab", mainDir = mainDir, error = err.msg
    result = false

proc removeDeadTabs(runtime: GuiRuntime) =
  var i = 0
  while i < runtime.tabs.len:
    let tab = runtime.tabs[i]
    if tab.isNil or (tab.client.isNil) or (not tab.client.isRunning()):
      if not tab.isNil and not tab.client.isNil:
        tab.client.stop()
      runtime.tabs.delete(i)
      continue
    inc i

  if runtime.tabs.len == 0:
    runtime.activeTab = -1
    runtime.hoverTab = -1
    runtime.client = nil
    runtime.state = nil
    runtime.hl = nil
    runtime.appRunning = false
    return

  if runtime.activeTab < 0 or runtime.activeTab >= runtime.tabs.len:
    runtime.activeTab = min(max(0, runtime.activeTab), runtime.tabs.len - 1)
  if runtime.hoverTab >= runtime.tabs.len:
    runtime.hoverTab = -1
  runtime.syncActiveAliases()

proc tabStripStartX(): float32 =
  when defined(macosx):
    TopBarLeadingPad + TopBarLeadingReserveMac
  else:
    TopBarLeadingPad

proc tabWidthForLabel(runtime: GuiRuntime, label: string): float32 =
  let textW = runeCount(label).float32 * runtime.cellW
  min(TopBarTabMaxWidth, max(TopBarTabMinWidth, textW + TopBarTabPadding * 2))

proc tabRects(
    runtime: GuiRuntime, logicalWidth: float32, newTabRect: var Rect
): seq[Rect] =
  var x = tabStripStartX()
  result = @[]
  for tab in runtime.tabs:
    let w = runtime.tabWidthForLabel(tab.label)
    if x + w > logicalWidth - TopBarNewTabWidth - TopBarTabGap:
      break
    result.add(rect(x, TopBarTabY, w, TopBarTabHeight))
    x += w + TopBarTabGap
  newTabRect = rect(x, TopBarTabY + 1, TopBarNewTabWidth, TopBarNewTabWidth)

proc pointInRect(p: Vec2, r: Rect): bool =
  p.x >= r.x and p.x < (r.x + r.w) and p.y >= r.y and p.y < (r.y + r.h)

proc topBarHit(runtime: GuiRuntime, mousePos: Vec2): tuple[tabIdx: int, newTab: bool] =
  let logicalWidth = runtime.window.logicalSize().x
  var newTabRect = rect(0, 0, 0, 0)
  let rects = runtime.tabRects(logicalWidth, newTabRect)
  for idx, r in rects:
    if pointInRect(mousePos, r):
      return (idx, false)
  if pointInRect(mousePos, newTabRect):
    return (-1, true)
  (-1, false)

proc addSingleLineText(
    renders: var Renders,
    zlevel: ZLevel,
    text: string,
    font: FigFont,
    color: Color,
    x, y, maxWidth: float32,
) =
  if text.len == 0 or maxWidth <= 1:
    return
  let maxRunes = max(1, int((maxWidth / max(1.0'f32, font.size * 0.55'f32))))
  var glyphs: seq[(Rune, Vec2)] = @[]
  var count = 0
  for r in text.runes:
    if count >= maxRunes:
      break
    glyphs.add((r, vec2(x + count.float32 * font.size * 0.55'f32, y)))
    inc count
  if glyphs.len == 0:
    return
  let layout = placeGlyphs(fs(font, color), glyphs, origin = GlyphTopLeft)
  discard renders.addRoot(
    zlevel,
    Fig(
      kind: nkText,
      childCount: 0,
      zlevel: zlevel,
      screenBox: rect(x, y, maxWidth, font.size),
      fill: color,
      textLayout: layout,
    ),
  )

proc offsetRendersY(renders: var Renders, yOffset: float32) =
  for _, list in renders.layers.mpairs:
    for i in 0 ..< list.nodes.len:
      list.nodes[i].screenBox.y += yOffset

proc renderTopBar(runtime: GuiRuntime, renders: var Renders, logicalSize: Vec2) =
  let z = 2.ZLevel
  discard renders.addRoot(
    z,
    Fig(
      kind: nkRectangle,
      childCount: 0,
      zlevel: z,
      screenBox: rect(0, 0, logicalSize.x, runtime.topBarHeight),
      fill: rgba(34, 38, 44, 255).color,
    ),
  )
  discard renders.addRoot(
    z,
    Fig(
      kind: nkRectangle,
      childCount: 0,
      zlevel: z,
      screenBox: rect(0, runtime.topBarHeight - 1, logicalSize.x, 1),
      fill: rgba(58, 64, 72, 255).color,
    ),
  )

  when not defined(macosx):
    let y = (runtime.topBarHeight - 12) / 2
    for i in 0 .. 2:
      let x = TopBarLeadingPad + i.float32 * 20
      let fill =
        if i == 0:
          rgba(214, 88, 88, 255).color
        elif i == 1:
          rgba(218, 177, 69, 255).color
        else:
          rgba(98, 188, 118, 255).color
      discard renders.addRoot(
        z,
        Fig(
          kind: nkRectangle,
          childCount: 0,
          zlevel: z,
          screenBox: rect(x, y, 12, 12),
          fill: fill,
        ),
      )

  var newTabRect = rect(0, 0, 0, 0)
  let rects = runtime.tabRects(logicalSize.x, newTabRect)
  for idx, box in rects:
    let tab = runtime.tabs[idx]
    let fill =
      if idx == runtime.activeTab:
        rgba(78, 123, 194, 255).color
      elif idx == runtime.hoverTab:
        rgba(70, 78, 90, 255).color
      else:
        rgba(52, 58, 66, 255).color
    discard renders.addRoot(
      z, Fig(kind: nkRectangle, childCount: 0, zlevel: z, screenBox: box, fill: fill)
    )
    renders.addSingleLineText(
      z,
      tab.label,
      runtime.monoFont,
      rgba(228, 236, 250, 255).color,
      box.x + TopBarTextInset,
      box.y + 11,
      max(20, box.w - TopBarTextInset * 2),
    )

  let plusFill =
    if runtime.hoverNewTab:
      rgba(76, 86, 98, 255).color
    else:
      rgba(56, 62, 70, 255).color
  discard renders.addRoot(
    z,
    Fig(
      kind: nkRectangle, childCount: 0, zlevel: z, screenBox: newTabRect, fill: plusFill
    ),
  )
  renders.addSingleLineText(
    z,
    "+",
    runtime.monoFont,
    rgba(236, 240, 248, 255).color,
    newTabRect.x + 12,
    newTabRect.y + 10,
    10,
  )

proc redrawGui*(runtime: GuiRuntime) =
  if runtime.state.isNil or runtime.hl.isNil:
    return
  runtime.renderer.beginFrame()
  let sz = runtime.window.logicalSize()
  let contentSz = runtime.contentLogicalSize()
  let phys = vec2(runtime.window.size())
  var renders = makeRenderTree(
    contentSz.x,
    contentSz.y,
    runtime.monoFont,
    runtime.state[],
    runtime.hl[],
    runtime.cellW,
    runtime.cellH,
  )
  renders.offsetRendersY(runtime.topBarHeight)
  runtime.renderTopBar(renders, sz)
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
  if runtime.client.isNil or (not runtime.client.isRunning()):
    runtime.removeDeadTabs()
    return false
  try:
    discard runtime.client.request(methodName, params)
    return true
  except CatchableError as err:
    warn "nvim request failed", rpcMethod = methodName, error = err.msg
    runtime.removeDeadTabs()
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
  if runtime.client.isNil or (not runtime.client.isRunning()):
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
  if runtime.state.isNil:
    return false
  case cmdShortcutAction(key)
  of csaCopy:
    runtime.state[].clearPanelHighlight()
    discard runtime.copyVisualSelectionToClipboard()
    true
  of csaPaste:
    runtime.state[].clearPanelHighlight()
    discard runtime.pasteClipboard()
    true
  of csaNone:
    false

proc tryResizeUi*(runtime: GuiRuntime)
proc adjustFontSize(runtime: GuiRuntime, delta: float32): bool

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

proc logicalMousePos(runtime: GuiRuntime): Vec2 =
  inputPosToLogical(
    vec2(ivec2(runtime.window.mouse.pos.x.int32, runtime.window.mouse.pos.y.int32)),
    runtime.window.inputUsesBackingPixels(),
    runtime.window.inputDeviceScale(),
  )

proc mouseCell(runtime: GuiRuntime): tuple[row, col: int] =
  if runtime.state.isNil:
    return (0, 0)
  let mousePos = runtime.logicalMousePos()
  let contentPos = vec2(mousePos.x, max(0.0'f32, mousePos.y - runtime.topBarHeight))
  result = mouseGridCell(
    contentPos, runtime.state.rows, runtime.state.cols, runtime.cellW, runtime.cellH
  )

proc handleTopBarHover(runtime: GuiRuntime, mousePos: Vec2): bool =
  var hoverTab = -1
  var hoverNewTab = false
  if mousePos.y < runtime.topBarHeight:
    let hit = runtime.topBarHit(mousePos)
    hoverTab = hit.tabIdx
    hoverNewTab = hit.newTab
  if hoverTab == runtime.hoverTab and hoverNewTab == runtime.hoverNewTab:
    return false
  runtime.hoverTab = hoverTab
  runtime.hoverNewTab = hoverNewTab
  if not runtime.state.isNil:
    runtime.state.needsRedraw = true
  true

proc mainDirForNewTab(runtime: GuiRuntime): string =
  let active = runtime.activeTabRef()
  if not active.isNil and active.mainDir.len > 0:
    return active.mainDir
  if runtime.baseMainDir.len > 0:
    return runtime.baseMainDir
  normalizedPath(getCurrentDir())

proc handleTopBarClick(runtime: GuiRuntime, mousePos: Vec2): bool =
  if mousePos.y >= runtime.topBarHeight:
    return false
  let hit = runtime.topBarHit(mousePos)
  if hit.newTab:
    discard runtime.addProcessTab(runtime.mainDirForNewTab())
    return true
  if hit.tabIdx >= 0:
    discard runtime.selectTab(hit.tabIdx)
    return true
  true

proc sendMouseInput(runtime: GuiRuntime, button, action: string, row, col: int): bool =
  if button.len == 0:
    return false
  if runtime.state.isNil:
    return false
  let mods = mouseModifierFlags(runtime.modifiers)
  runtime.state[].setPanelHighlight(row, col)
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
  if runtime.state.isNil:
    return false
  let cell = runtime.mouseCell()
  let multiInput = multiClickToNvimInput(clickCount, cell.row, cell.col)
  if multiInput.len == 0:
    return false
  runtime.state[].setPanelHighlight(cell.row, cell.col)
  result = runtime.safeRequest("nvim_input", rpcPackParams(multiInput))

proc handleKeyPress(runtime: GuiRuntime, key: siwin.Key, modifiers: ModifierView) =
  if runtime.state.isNil:
    return
  runtime.state[].clearCommittedCmdline()
  let ctrlDown = siwin.ModifierKey.control in modifiers
  let shiftDown = siwin.ModifierKey.shift in modifiers
  let altDown = siwin.ModifierKey.alt in modifiers
  let fontDelta = fontSizeDeltaForShortcut(key, modifiers)
  if fontDelta != 0.0'f32:
    runtime.state[].clearPanelHighlight()
    discard runtime.adjustFontSize(fontDelta)
    return
  if clipboardShortcutModifierDown(modifiers) and runtime.handleCmdShortcut(key):
    return
  runtime.state[].clearPanelHighlight()
  if key == siwin.Key.enter and runtime.state.cmdlineActive:
    runtime.state.cmdlineCommitPending = true
  if key == siwin.Key.escape:
    runtime.state.cmdlineCommitPending = false
    runtime.state.cmdlineCommittedText = ""
  let input = keyToNvimInput(key, ctrlDown, altDown, shiftDown)
  trace "input key mapped",
    key = $key, modifiers = formatModifierSet(modifiers), mapped = input
  if input.len > 0:
    discard runtime.safeRequest("nvim_input", rpcPackParams(input))

proc adjustFontSize(runtime: GuiRuntime, delta: float32): bool =
  if delta == 0.0'f32:
    return false
  let current = runtime.monoFont.size
  let next = min(FontSizeMax, max(FontSizeMin, current + delta))
  if abs(next - current) < 0.0001'f32:
    return false
  runtime.monoFont.size = next
  runtime.config.fontSize = next
  let (cellW, cellH) = monoMetrics(runtime.monoFont)
  runtime.cellW = cellW
  runtime.cellH = cellH
  runtime.tryResizeUi()
  if not runtime.state.isNil:
    runtime.state.needsRedraw = true
  when not defined(emscripten):
    sleep(8)
  info "font size", previous = current, current = next, cellW = cellW, cellH = cellH
  result = true

proc tryResizeUi*(runtime: GuiRuntime) =
  if runtime.tabs.len == 0:
    return
  let sz = runtime.contentLogicalSize()
  let newSz = computeGridSize(sz, runtime.cellW, runtime.cellH)
  for tab in runtime.tabs:
    if tab.isNil or tab.state.isNil:
      continue
    if newSz.rows == tab.state.rows and newSz.cols == tab.state.cols:
      continue
    tab.state[].resize(newSz.rows, newSz.cols)
    if not tab.client.isNil and tab.client.isRunning():
      try:
        discard tab.client.request(
          "nvim_ui_try_resize", rpcPackParams(newSz.cols, newSz.rows)
        )
      except CatchableError as err:
        warn "nvim_ui_try_resize failed", tabId = tab.id, error = err.msg
  if not runtime.state.isNil:
    runtime.state.needsRedraw = true

proc handleGuiTest*(runtime: GuiRuntime) =
  let cfg = runtime.testCfg
  if not cfg.enabled:
    return
  if runtime.state.isNil:
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
  for tab in runtime.tabs:
    if not tab.isNil and not tab.client.isNil:
      tab.client.poll()
  runtime.removeDeadTabs()
  if runtime.tabs.len == 0:
    return false
  runtime.handleGuiTest()
  var didRedraw = false
  if (not runtime.state.isNil) and runtime.state.needsRedraw:
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
  for tab in runtime.tabs:
    if not tab.isNil and not tab.client.isNil:
      tab.client.stop()

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

proc scrollDirectionInvertedFromEnv*(): bool =
  const EnvKey = "NEONIM_SCROLL_INVERT"
  let raw = getEnv(EnvKey)
  if raw.len == 0:
    return false
  case raw.strip().toLowerAscii()
  of "1", "true", "yes", "on":
    true
  of "0", "false", "no", "off":
    false
  else:
    warn "invalid scroll invert flag, expected boolean", env = EnvKey, value = raw
    false

proc fontSizeFromEnv*(): float32 =
  const EnvKey = "NEONIM_FONTSIZE"
  let raw = getEnv(EnvKey)
  if raw.len == 0:
    return DefaultFontSize
  try:
    let parsed = raw.parseFloat().float32
    if parsed > 0:
      return parsed
    warn "invalid font size, must be > 0", env = EnvKey, value = raw
  except ValueError:
    warn "invalid font size, must be numeric", env = EnvKey, value = raw
  DefaultFontSize

proc uiScaleFromEnv*(fallbackScale: float32): float32 =
  const EnvKey = "NEONIM_HDI"
  let raw = getEnv(EnvKey)
  if raw.len == 0:
    return fallbackScale
  try:
    let parsed = raw.parseFloat().float32
    if parsed > 0:
      return parsed
    warn "invalid ui scale, must be > 0", env = EnvKey, value = raw
  except ValueError:
    warn "invalid ui scale, must be numeric", env = EnvKey, value = raw
  fallbackScale

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
  result.scrollDirectionInverted = scrollDirectionInvertedFromEnv()
  result.testStart = epochTime()
  result.figNodesDumpPath = getEnv("NEONIM_FIG_NODES_OUT")
  let size = ivec2(1000, 700)
  let title = "Neonim"
  let typefaceId = loadTypeface(config.fontTypeface, [config.defaultTypeface])
  result.monoFont = FigFont(typefaceId: typefaceId, size: config.fontSize)
  when UseVulkanBackend:
    result.renderer =
      newFigRenderer(atlasSize = 4096, backendState = siwin.SiwinRenderBackend())
    result.window = siwin.newSiwinWindow(
      result.renderer, size = size, fullscreen = false, title = title
    )
  else:
    result.window = siwin.newSiwinWindow(size = size, fullscreen = false, title = title)
    result.renderer =
      newFigRenderer(atlasSize = 4096, backendState = siwin.SiwinRenderBackend())
  result.mouseDown = {}
  result.modifiers = {}
  result.lastScroll = vec2(0, 0)
  result.topBarHeight = TopBarHeight
  result.hoverTab = -1
  result.hoverNewTab = false
  result.activeTab = -1
  result.nextTabId = 1
  result.baseMainDir = guessMainDir(config.nvimArgs)
  trySetWindowIcon(result.window)

  setFigUiScale uiScaleFromEnv(result.window.contentScale())
  if size != size.scaled():
    result.window.size = size.scaled()

  result.renderer.setupBackend(result.window)
  let (cellW, cellH) = monoMetrics(result.monoFont)
  result.cellW = cellW
  result.cellH = cellH
  warn "mono metrics: ", cellW = cellW, cellH = cellH

  let runtime = result
  if not runtime.addProcessTab(runtime.baseMainDir, config.nvimArgs):
    raise newException(NeovimError, "failed to launch initial nvim process tab")

  runtime.window.eventsHandler.onClose = proc(_: siwin.CloseEvent) =
    runtime.appRunning = false
  runtime.window.eventsHandler.onResize = proc(_: siwin.ResizeEvent) =
    runtime.tryResizeUi()
    if not runtime.state.isNil:
      runtime.state.needsRedraw = true

  runtime.window.eventsHandler.onMouseMove = proc(_: siwin.MouseMoveEvent) =
    let mousePos = runtime.logicalMousePos()
    discard runtime.handleTopBarHover(mousePos)
    let dragButton = mouseDragButtonToNvimButton(runtime.mouseDown)
    if dragButton.len == 0:
      return
    if mousePos.y < runtime.topBarHeight:
      return
    let cell = runtime.mouseCell()
    discard runtime.sendMouseInput(dragButton, "drag", cell.row, cell.col)

  runtime.window.eventsHandler.onScroll = proc(e: siwin.ScrollEvent) =
    if runtime.logicalMousePos().y < runtime.topBarHeight:
      return
    runtime.lastScroll = vec2(e.deltaX.float32, e.delta.float32)
    let actions = mouseScrollActions(
      runtime.lastScroll,
      speedMultiplier = runtime.scrollSpeedMultiplier,
      invertDirection = runtime.scrollDirectionInverted,
    )
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
    if runtime.state.isNil:
      return
    runtime.state[].clearPanelHighlight()
    runtime.state[].clearCommittedCmdline()
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
      if e.button == siwin.MouseButton.left and
          runtime.handleTopBarClick(runtime.logicalMousePos()):
        return
      runtime.mouseDown.incl(e.button)
      discard runtime.handleMouseButton(e.button, "press")
    else:
      if e.button notin runtime.mouseDown:
        return
      runtime.mouseDown.excl(e.button)
      discard runtime.handleMouseButton(e.button, "release")

  runtime.window.eventsHandler.onClick = proc(e: siwin.ClickEvent) =
    if e.double and e.button == siwin.MouseButton.left and
        runtime.logicalMousePos().y >= runtime.topBarHeight:
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
    fontTypeface: getEnv("NEONIM_FONT", "HackNerdFont-Regular.ttf"),
    defaultTypeface: "HackNerdFont-Regular.ttf",
    fontSize: fontSizeFromEnv(),
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
