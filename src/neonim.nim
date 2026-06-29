## Neonim - Neovim GUI backend in Nim.
##
import std/[streams, os, osproc, strutils, times, unicode, tables, options]
import chronicles

import libbacktrace

import vmath
import msgpack4nim
import pkg/pixie
import merenda/nimkit as nk except Rect, Size, Point, Color
import sigils/core
import siwin/[clipboards, colorutils]
import figdraw/windowing/siwinshim as siwin

import figdraw/commons
import figdraw/common/fonttypes
import ./neonim/[types, rpc, nvim_client, ui_linegrid, gui_backend]

const
  EmbeddedWindowIconPng = staticRead("../data/neonim-icon-128.png")
  NeonimWindowBackendName = "siwin"
  NvimDirChangedMethod = "neonim_dir_changed"
  DefaultFontSize = 16.0'f32
  TopBarHeight = 35.0'f32

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

  NeonimEditor = ref object of nk.MonoTextView
    runtime: GuiRuntime

  GuiRuntime* = ref object of nk.Responder
    config*: GuiConfig
    testCfg*: GuiTestConfig
    appRunning*: bool
    testStart*: float
    testSent*: bool
    testPassed*: bool
    window*: siwin.Window
    app*: nk.Application
    kitWindow*: nk.Window
    rootView*: nk.View
    layoutView*: nk.StackView
    documentTabs*: nk.DocumentTabs
    editor*: NeonimEditor
    modifiers: ModifierView
    tabs: seq[NvimProcessTab]
    activeTab: int
    nextTabId: int
    topBarHeight: float32
    baseMainDir: string
    client*: NeovimClient
    monoFont*: FigFont
    cellW*: float32
    cellH*: float32
    scrollSpeedMultiplier*: float32
    scrollDirectionInverted*: bool
    iconRetriedAfterFirstStep: bool
    suppressDocumentTabCallbacks: bool
    tabsNeedSync: bool
    state*: LineGridStateRef
    hl*: HlStateRef
    frameIdle*: int
    cursorBlinkStart*: float
    cursorBlinkRow*: int
    cursorBlinkCol*: int
    cursorBlinkModeIdx*: int
    cursorVisible*: bool

proc computeGridSize(size: Vec2, cellW, cellH: float32): tuple[rows, cols: int] =
  let cols = max(1, int(size.x / cellW))
  let rows = max(1, int(size.y / cellH / 2))
  (rows, cols)

proc contentLogicalSize(runtime: GuiRuntime): Vec2 =
  if not runtime.editor.isNil:
    let bounds = runtime.editor.bounds()
    if bounds.size.width > 0.0'f32 and bounds.size.height > 0.0'f32:
      return vec2(bounds.size.width, bounds.size.height)
  if not runtime.kitWindow.isNil:
    let size = runtime.kitWindow.frame().size
    if size.width > 0.0'f32 and size.height > 0.0'f32:
      return vec2(size.width, max(1.0'f32, size.height - runtime.topBarHeight))
  if runtime.window.isNil:
    return vec2(1000.0'f32, max(1.0'f32, 700.0'f32 - runtime.topBarHeight))
  let sz = runtime.window.logicalSize()
  vec2(sz.x, max(1.0'f32, sz.y - runtime.topBarHeight))

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
  homeShortPath(mainDir)

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

proc activeTabRef(runtime: GuiRuntime): NvimProcessTab =
  if runtime.tabs.len == 0:
    return nil
  if runtime.activeTab < 0 or runtime.activeTab >= runtime.tabs.len:
    runtime.activeTab = min(max(0, runtime.activeTab), runtime.tabs.len - 1)
  runtime.tabs[runtime.activeTab]

proc tabIdentifier(tab: NvimProcessTab): string =
  if tab.isNil:
    ""
  else:
    $tab.id

proc tabIndexForIdentifier(runtime: GuiRuntime, identifier: string): int =
  for idx, tab in runtime.tabs:
    if tab.tabIdentifier() == identifier:
      return idx
  -1

proc syncDocumentTabs(runtime: GuiRuntime) =
  if runtime.isNil or runtime.documentTabs.isNil:
    return

  runtime.suppressDocumentTabCallbacks = true
  runtime.documentTabs.removeAllDocumentTabs()
  for tab in runtime.tabs:
    if tab.isNil:
      continue
    let item = nk.newDocumentTabItem(
      title = tab.label, identifier = tab.tabIdentifier(), closeable = true
    )
    discard runtime.documentTabs.addDocumentTabItem(item)
  if runtime.activeTab >= 0 and runtime.activeTab < runtime.documentTabs.len():
    discard runtime.documentTabs.selectDocumentTabAtIndex(runtime.activeTab)
  runtime.suppressDocumentTabCallbacks = false

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
  runtime.cursorBlinkStart = epochTime()
  runtime.cursorBlinkRow = -1
  runtime.cursorBlinkCol = -1
  runtime.cursorBlinkModeIdx = -1
  runtime.cursorVisible = true

proc selectTab(runtime: GuiRuntime, idx: int): bool =
  if idx < 0 or idx >= runtime.tabs.len:
    return false
  runtime.activeTab = idx
  runtime.syncActiveAliases()
  if not runtime.state.isNil:
    runtime.state.needsRedraw = true
  if not runtime.documentTabs.isNil and runtime.documentTabs.selectedIndex() != idx:
    runtime.suppressDocumentTabCallbacks = true
    discard runtime.documentTabs.selectDocumentTabAtIndex(idx)
    runtime.suppressDocumentTabCallbacks = false
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

proc installDirChangedAutocmd(client: NeovimClient, channelId: int64) =
  let lua =
    """
local channel = ...
local group = vim.api.nvim_create_augroup('NeonimProcessTabs', { clear = true })
local function neonim_main_dir()
  return vim.fn.getcwd()
end

vim.api.nvim_create_autocmd({ 'DirChanged' }, {
  group = group,
  callback = function()
    vim.rpcnotify(channel, 'neonim_dir_changed', neonim_main_dir())
  end,
})
vim.schedule(function()
  vim.rpcnotify(channel, 'neonim_dir_changed', neonim_main_dir())
end)
"""
  let resp =
    client.callAndWait("nvim_exec_lua", rpcPackParams(lua, @[channelId]), timeout = 1.0)
  if not resp.error.isNilValue:
    var errText = "unknown error"
    try:
      errText = rpcUnpack[string](resp.error)
    except CatchableError:
      discard
    raise newException(NeovimError, "nvim_exec_lua failed: " & errText)

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
  let metadata = client.discoverMetadata()

  new(result)
  result.id = runtime.nextTabId
  inc runtime.nextTabId
  result.mainDir = tabDir
  result.label = tabLabelForDir(result.mainDir)
  result.client = client
  result.state = stateRef
  result.hl = hlRef

  let tabRef = result
  client.onNotification = proc(methodName: string, params: RpcParamsBuffer) =
    if methodName == "redraw":
      handleRedraw(tabRef.state[], tabRef.hl[], params)
    elif methodName == NvimDirChangedMethod:
      try:
        var args: seq[string] = @[]
        var nextRaw = ""
        try:
          rpcUnpack(params, args)
          if args.len > 0:
            nextRaw = args[0]
        except CatchableError:
          rpcUnpack(params, nextRaw)
        if nextRaw.len == 0:
          return
        let nextDir = normalizedExistingDir(nextRaw, tabRef.mainDir)
        if nextDir == tabRef.mainDir:
          return
        tabRef.mainDir = nextDir
        tabRef.label = tabLabelForDir(nextDir)
        runtime.tabsNeedSync = true
        if not tabRef.state.isNil:
          tabRef.state.needsRedraw = true
      except CatchableError as err:
        warn "failed to update tab dir from nvim notification", error = err.msg

  try:
    client.installDirChangedAutocmd(metadata.channelId)
  except CatchableError as err:
    warn "failed to install nvim DirChanged autocmd", error = err.msg

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

proc addProcessTab(
    runtime: GuiRuntime, mainDir: string, nvimArgs: seq[string] = @[]
): bool =
  try:
    runtime.tabs.add(runtime.createProcessTab(mainDir, nvimArgs))
    discard runtime.selectTab(runtime.tabs.len - 1)
    runtime.syncDocumentTabs()
    result = true
  except CatchableError as err:
    warn "failed to create nvim tab", mainDir = mainDir, error = err.msg
    result = false

proc closeTab(runtime: GuiRuntime, idx: int): bool =
  if idx < 0 or idx >= runtime.tabs.len:
    return false
  let closing = runtime.tabs[idx]
  if not closing.isNil and not closing.client.isNil:
    closing.client.stop()
  let wasActive = idx == runtime.activeTab
  runtime.tabs.delete(idx)

  if runtime.tabs.len == 0:
    runtime.activeTab = -1
    runtime.client = nil
    runtime.state = nil
    runtime.hl = nil
    runtime.appRunning = false
    runtime.syncDocumentTabs()
    return true

  if wasActive:
    runtime.activeTab =
      if idx > 0:
        idx - 1
      else:
        0
  elif idx < runtime.activeTab:
    dec runtime.activeTab

  runtime.syncActiveAliases()
  if not runtime.state.isNil:
    runtime.state.needsRedraw = true
  runtime.syncDocumentTabs()
  result = true

proc removeDeadTabs(runtime: GuiRuntime) =
  var changed = false
  var i = 0
  while i < runtime.tabs.len:
    let tab = runtime.tabs[i]
    if tab.isNil or (tab.client.isNil) or (not tab.client.isRunning()):
      if not tab.isNil and not tab.client.isNil:
        tab.client.stop()
      runtime.tabs.delete(i)
      changed = true
      continue
    inc i

  if runtime.tabs.len == 0:
    runtime.activeTab = -1
    runtime.client = nil
    runtime.state = nil
    runtime.hl = nil
    runtime.appRunning = false
    if changed:
      runtime.syncDocumentTabs()
    return

  if runtime.activeTab < 0 or runtime.activeTab >= runtime.tabs.len:
    runtime.activeTab = min(max(0, runtime.activeTab), runtime.tabs.len - 1)
  runtime.syncActiveAliases()
  if changed:
    runtime.syncDocumentTabs()

protocol NeonimDocumentTabsDelegate of nk.DocumentTabsDelegate:
  method didSelectDocumentTab(
      runtime: GuiRuntime, tabs: nk.DocumentTabs, item: nk.DocumentTabItem
  ) =
    discard tabs
    if runtime.suppressDocumentTabCallbacks:
      return
    let idx = runtime.tabIndexForIdentifier(item.identifier())
    if idx >= 0:
      discard runtime.selectTab(idx)

  method shouldCloseDocumentTab(
      runtime: GuiRuntime, tabs: nk.DocumentTabs, item: nk.DocumentTabItem, index: int
  ): bool =
    discard tabs
    discard item
    not runtime.suppressDocumentTabCallbacks and index >= 0 and index < runtime.tabs.len

  method didCloseDocumentTab(
      runtime: GuiRuntime, tabs: nk.DocumentTabs, item: nk.DocumentTabItem, index: int
  ) =
    discard tabs
    discard item
    if runtime.suppressDocumentTabCallbacks:
      return
    discard runtime.closeTab(index)

  method didMoveDocumentTab(
      runtime: GuiRuntime,
      tabs: nk.DocumentTabs,
      item: nk.DocumentTabItem,
      fromIndex: int,
      toIndex: int,
  ) =
    discard tabs
    discard item
    if runtime.suppressDocumentTabCallbacks:
      return
    if fromIndex < 0 or fromIndex >= runtime.tabs.len:
      return
    let bounded = max(0, min(toIndex, runtime.tabs.high))
    if bounded == fromIndex:
      return
    let selected = runtime.activeTabRef()
    let moving = runtime.tabs[fromIndex]
    runtime.tabs.delete(fromIndex)
    runtime.tabs.insert(moving, bounded)
    runtime.activeTab = -1
    for idx, tab in runtime.tabs:
      if tab == selected:
        runtime.activeTab = idx
        break
    runtime.syncActiveAliases()
    runtime.syncDocumentTabs()

proc monoCursorStyle(style: CursorStyle): nk.MonoTextCursorStyle =
  case style.shape
  of csVertical: nk.mtcVertical
  of csHorizontal: nk.mtcUnderline
  of csBlock: nk.mtcBlock

proc cursorInGrid(state: LineGridState): bool =
  state.cursorRow >= 0 and state.cursorRow < state.rows and state.cursorCol >= 0 and
    state.cursorCol < state.cols

proc blockCursorSwapsCell(state: LineGridState, cursorVisible: bool): bool =
  if not cursorVisible or not state.cursorInGrid():
    return false
  state.cursorStyleEnabled and state.currentCursorStyle().shape == csBlock

proc monoCellFor(
    state: LineGridState,
    hl: HlState,
    row, col: int,
    highlightStart, highlightStop: int,
    blockCursorActive: bool,
): nk.MonoTextCell =
  let cell = state.renderedCell(row, col)
  var colors = resolveCellColors(state, hl, cell.hlId)
  var bg = colors.bg

  if row == state.panelHighlightRow and col >= highlightStart and col < highlightStop:
    bg = some(PanelHighlightFill)

  if blockCursorActive and row == state.cursorRow and col == state.cursorCol:
    let cursorColors =
      resolveCursorCellColors(state, hl, cell, state.currentCursorStyle())
    return nk.initMonoTextCell(
      cell.text,
      foregroundColor = cursorColors.text,
      backgroundColor = cursorColors.fill,
      hasForegroundColor = true,
      hasBackgroundColor = true,
    )

  nk.initMonoTextCell(
    cell.text,
    foregroundColor = colors.fg,
    backgroundColor =
      if bg.isSome:
        bg.get()
      else:
        state.colors.bg,
    hasForegroundColor = true,
    hasBackgroundColor = bg.isSome,
  )

proc syncEditorView(runtime: GuiRuntime) =
  if runtime.isNil or runtime.editor.isNil or runtime.state.isNil or runtime.hl.isNil:
    return

  let state = runtime.state[]
  let hl = runtime.hl[]
  runtime.editor.backgroundColor = state.colors.bg
  runtime.editor.textColor = state.colors.fg
  runtime.editor.setGridSize(state.rows, state.cols)

  let highlight =
    if state.panelHighlightRow >= 0:
      state.panelHighlightColumns()
    else:
      (startCol: 0, endColExclusive: 0)
  let blockCursorActive = state.blockCursorSwapsCell(runtime.cursorVisible)
  for row in 0 ..< state.rows:
    var rowCells = newSeq[nk.MonoTextCell](state.cols)
    for col in 0 ..< state.cols:
      rowCells[col] = monoCellFor(
        state, hl, row, col, highlight.startCol, highlight.endColExclusive,
        blockCursorActive,
      )
    runtime.editor.replaceCells(row, 0, rowCells)

  if state.cursorInGrid():
    runtime.editor.setCursorPosition(state.cursorRow, state.cursorCol)
    let style = state.currentCursorStyle()
    runtime.editor.cursorStyle =
      if state.cursorStyleEnabled:
        style.monoCursorStyle()
      else:
        nk.mtcBlock
    let cursorColors = resolveCursorCellColors(
      state, hl, state.renderedCell(state.cursorRow, state.cursorCol), style
    )
    runtime.editor.cursorColor =
      if state.cursorStyleEnabled:
        cursorColors.fill
      else:
        rgba(220, 220, 220, 80).color
    runtime.editor.cursorVisible = runtime.cursorVisible and not blockCursorActive
  else:
    runtime.editor.cursorVisible = false

proc updateCursorBlink(runtime: GuiRuntime): bool =
  if runtime.state.isNil:
    runtime.cursorVisible = true
    return false
  let state = runtime.state[]
  if state.cursorRow != runtime.cursorBlinkRow or
      state.cursorCol != runtime.cursorBlinkCol or
      state.currentModeIdx != runtime.cursorBlinkModeIdx:
    runtime.cursorBlinkRow = state.cursorRow
    runtime.cursorBlinkCol = state.cursorCol
    runtime.cursorBlinkModeIdx = state.currentModeIdx
    runtime.cursorBlinkStart = epochTime()
    if not runtime.cursorVisible:
      runtime.cursorVisible = true
      return true

  if not state.cursorBlinkActive():
    if not runtime.cursorVisible:
      runtime.cursorVisible = true
      return true
    return false

  let style = state.currentCursorStyle()
  let elapsedMs = max(0.0, (epochTime() - runtime.cursorBlinkStart) * 1000.0)
  let shouldShow =
    if elapsedMs < style.blinkwait.float:
      true
    else:
      let cycle = style.blinkon + style.blinkoff
      let phase = int(elapsedMs - style.blinkwait.float) mod cycle
      phase < style.blinkon
  if shouldShow != runtime.cursorVisible:
    runtime.cursorVisible = shouldShow
    return true
  false

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
    if not runtime.kitWindow.isNil:
      discard nk.generalPasteboard().setPlainText(copiedText)
    elif not runtime.window.isNil:
      runtime.window.clipboard.text = copiedText
    return true
  except CatchableError as err:
    warn "copy shortcut failed", error = err.msg
    return false

proc pasteClipboard(runtime: GuiRuntime): bool =
  try:
    let clipboardText =
      if not runtime.kitWindow.isNil:
        nk.generalPasteboard().plainText()
      elif not runtime.window.isNil:
        runtime.window.clipboard.text()
      else:
        ""
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

proc sourceDataDir(): string =
  normalizedPath(parentDir(currentSourcePath()) / ".." / "data")

proc formatModifierSet(modifiers: ModifierView): string {.used.} =
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

proc formatInputText(text: string): string {.used.} =
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

proc mainDirForNewTab(runtime: GuiRuntime): string =
  let active = runtime.activeTabRef()
  if not active.isNil and active.mainDir.len > 0:
    return active.mainDir
  if runtime.baseMainDir.len > 0:
    return runtime.baseMainDir
  normalizedPath(getCurrentDir())

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

proc selectTabByOffset(runtime: GuiRuntime, offset: int): bool =
  let n = runtime.tabs.len
  if n <= 0:
    return false
  var idx = runtime.activeTab
  if idx < 0 or idx >= n:
    idx = 0
  let next = ((idx + offset) mod n + n) mod n
  result = runtime.selectTab(next)

proc toSiwinKey(key: nk.Key): siwin.Key =
  static:
    doAssert ord(nk.keyA) == ord(siwin.Key.a)
    doAssert ord(nk.keyNumpadDot) == ord(siwin.Key.npadDot)
    doAssert ord(nk.keyLevel5Shift) == ord(siwin.Key.level5_shift)
  if key.ord < ord(low(siwin.Key)) or key.ord > ord(high(siwin.Key)):
    return siwin.Key.unknown
  siwin.Key(key.ord)

proc toSiwinModifiers(modifiers: set[nk.KeyModifier]): ModifierView =
  if nk.kmShift in modifiers:
    result.incl siwin.ModifierKey.shift
  if nk.kmControl in modifiers:
    result.incl siwin.ModifierKey.control
  if nk.kmOption in modifiers:
    result.incl siwin.ModifierKey.alt
  if nk.kmCommand in modifiers:
    result.incl siwin.ModifierKey.system

proc toSiwinMouseButton(button: nk.MouseButton): siwin.MouseButton =
  case button
  of nk.mbPrimary: siwin.MouseButton.left
  of nk.mbSecondary: siwin.MouseButton.right
  of nk.mbOther: siwin.MouseButton.middle

proc handleKeyPress(runtime: GuiRuntime, key: siwin.Key, modifiers: ModifierView) =
  if runtime.state.isNil:
    return
  runtime.state[].clearCommittedCmdline()
  let ctrlDown = siwin.ModifierKey.control in modifiers
  let shiftDown = siwin.ModifierKey.shift in modifiers
  let altDown = siwin.ModifierKey.alt in modifiers
  let cmdDown = siwin.ModifierKey.system in modifiers
  let fontDelta = fontSizeDeltaForShortcut(key, modifiers)
  if fontDelta != 0.0'f32:
    runtime.state[].clearPanelHighlight()
    discard runtime.adjustFontSize(fontDelta)
    return
  let newTabShortcutDown =
    when defined(macosx):
      cmdDown
    else:
      ctrlDown and shiftDown
  if newTabShortcutDown and key == siwin.Key.t:
    runtime.state[].clearPanelHighlight()
    discard runtime.addProcessTab(runtime.mainDirForNewTab())
    return
  if cmdDown and shiftDown:
    if key == siwin.Key.lbracket:
      runtime.state[].clearPanelHighlight()
      discard runtime.selectTabByOffset(-1)
      return
    if key == siwin.Key.rbracket:
      runtime.state[].clearPanelHighlight()
      discard runtime.selectTabByOffset(1)
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

proc handleNeonimTextInput(editor: NeonimEditor, text: string) =
  if editor.isNil or editor.runtime.isNil:
    return
  let runtime = editor.runtime
  trace "input text event",
    text = formatInputText(text),
    modifiers = formatModifierSet(runtime.modifiers),
    repeated = false
  if runtime.state.isNil:
    return
  if siwin.ModifierKey.control in runtime.modifiers:
    return
  if siwin.ModifierKey.alt in runtime.modifiers:
    return
  if siwin.ModifierKey.system in runtime.modifiers:
    return
  runtime.state[].clearPanelHighlight()
  runtime.state[].clearCommittedCmdline()
  for r in text.runes:
    let code = int(r)
    if code < 32 or code == 127:
      continue
    discard runtime.safeRequest("nvim_input", rpcPackParams(runeToNvimInput(r)))

protocol NeonimEditorInput of nk.TextInputProtocol:
  method insertText(editor: NeonimEditor, text: string) =
    editor.handleNeonimTextInput(text)

proc handleMonoTextRawEvent(runtime: GuiRuntime, event: nk.MonoTextRawEvent): bool =
  if runtime.isNil:
    return true
  case event.kind
  of nk.mtreKeyDown:
    runtime.modifiers = event.keyEvent.modifiers.toSiwinModifiers()
    runtime.handleKeyPress(event.keyEvent.key.toSiwinKey(), runtime.modifiers)
  of nk.mtreFlagsChanged:
    runtime.modifiers = event.keyEvent.modifiers.toSiwinModifiers()
  of nk.mtreMouseDown:
    runtime.modifiers = event.mouseEvent.modifiers.toSiwinModifiers()
    if event.mouseEvent.clickCount >= 2 and event.mouseEvent.clickCount <= 4:
      if not runtime.state.isNil:
        runtime.state[].setPanelHighlight(event.row, event.column)
      let input =
        multiClickToNvimInput(event.mouseEvent.clickCount, event.row, event.column)
      if input.len > 0:
        discard runtime.safeRequest("nvim_input", rpcPackParams(input))
    else:
      let button = mouseButtonToNvimButton(event.mouseEvent.button.toSiwinMouseButton())
      discard runtime.sendMouseInput(button, "press", event.row, event.column)
  of nk.mtreMouseDragged:
    runtime.modifiers = event.mouseEvent.modifiers.toSiwinModifiers()
    let button = mouseButtonToNvimButton(event.mouseEvent.button.toSiwinMouseButton())
    discard runtime.sendMouseInput(button, "drag", event.row, event.column)
  of nk.mtreMouseUp:
    runtime.modifiers = event.mouseEvent.modifiers.toSiwinModifiers()
    let button = mouseButtonToNvimButton(event.mouseEvent.button.toSiwinMouseButton())
    discard runtime.sendMouseInput(button, "release", event.row, event.column)
  of nk.mtreScrollWheel:
    runtime.modifiers = event.scrollEvent.modifiers.toSiwinModifiers()
    let actions = mouseScrollActions(
      vec2(event.scrollEvent.deltaX, event.scrollEvent.deltaY),
      speedMultiplier = runtime.scrollSpeedMultiplier,
      invertDirection = runtime.scrollDirectionInverted,
    )
    for action in actions:
      discard runtime.sendMouseInput("wheel", action, event.row, event.column)
  true

proc adjustFontSize(runtime: GuiRuntime, delta: float32): bool =
  if delta == 0.0'f32:
    return false
  let current = runtime.monoFont.size
  let next = min(FontSizeMax, max(FontSizeMin, current + delta))
  if abs(next - current) < 0.0001'f32:
    return false
  runtime.monoFont.size = next
  runtime.config.fontSize = next
  if not runtime.editor.isNil:
    runtime.editor.fontSize = next
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

proc stepGui*(runtime: GuiRuntime): bool =
  if runtime.isNil:
    return false
  if not runtime.app.isNil:
    discard runtime.app.runForFrames(1)
  if not runtime.kitWindow.isNil and runtime.kitWindow.isClosed():
    runtime.appRunning = false
  runtime.tryResizeUi()
  if not runtime.iconRetriedAfterFirstStep:
    if not runtime.kitWindow.isNil:
      let nativeWindow = runtime.kitWindow.nativeWindowOrNil()
      if not nativeWindow.isNil:
        trySetWindowIcon(nativeWindow)
    elif not runtime.window.isNil:
      trySetWindowIcon(runtime.window)
    runtime.iconRetriedAfterFirstStep = true
  for tab in runtime.tabs:
    if not tab.isNil and not tab.client.isNil:
      tab.client.poll()
  runtime.removeDeadTabs()
  if runtime.tabs.len == 0:
    return false
  if runtime.tabsNeedSync:
    runtime.syncDocumentTabs()
    runtime.tabsNeedSync = false
  runtime.handleGuiTest()
  if runtime.updateCursorBlink() and not runtime.state.isNil:
    runtime.state.needsRedraw = true
  var didRedraw = false
  if (not runtime.state.isNil) and runtime.state.needsRedraw:
    runtime.syncEditorView()
    runtime.state.needsRedraw = false
    didRedraw = true
    runtime.frameIdle = 0
  when not defined(emscripten):
    if not didRedraw:
      if (not runtime.state.isNil) and runtime.state[].cursorBlinkActive():
        runtime.frameIdle = 0
        sleep(16)
      else:
        runtime.frameIdle = min(runtime.frameIdle + 1, 1024)
        #if runtime.frameIdle mod 8 == 0:
        #  echo "sleep time: ", (runtime.frameIdle div 8), " idle: ", runtime.frameIdle
        sleep(runtime.frameIdle div 8)
  result = runtime.appRunning

proc shutdownGui*(runtime: GuiRuntime) =
  when not defined(emscripten):
    if not runtime.kitWindow.isNil and not runtime.kitWindow.isClosed():
      runtime.kitWindow.close()
    elif not runtime.window.isNil:
      runtime.window.close()
  if not runtime.app.isNil:
    runtime.app.stop()
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

proc registerBundledTypeface(name: string) =
  case name
  of "HackNerdFont-Regular.ttf":
    registerStaticTypeface(
      "HackNerdFont-Regular.ttf", ".." / "data" / "HackNerdFont-Regular.ttf"
    )
  of "Ubuntu.ttf":
    registerStaticTypeface("Ubuntu.ttf", ".." / "data" / "Ubuntu.ttf")
  else:
    discard

proc newNeonimEditor(runtime: GuiRuntime, frame: nk.Rect): NeonimEditor =
  result = NeonimEditor()
  nk.initMonoTextViewFields(result, frame = frame, editable = true)
  result.runtime = runtime
  discard result.withProtocol(NeonimEditorInput)

proc buildNimKitViews(runtime: GuiRuntime, frame: nk.Rect) =
  runtime.app = nk.sharedApplication()
  runtime.kitWindow = nk.newWindow(runtime.config.windowTitle, frame = frame)
  runtime.rootView = nk.newView()
  runtime.layoutView = nk.newStackView(nk.laVertical)
  runtime.documentTabs = nk.newDocumentTabs()
  runtime.editor = newNeonimEditor(
    runtime,
    nk.initRect(
      0.0'f32,
      0.0'f32,
      frame.size.width,
      max(1.0'f32, frame.size.height - runtime.topBarHeight),
    ),
  )

  runtime.documentTabs.delegate = runtime
  runtime.documentTabs.defaultTabStyle = nk.dtsRounded
  runtime.documentTabs.showsHorizontalScroller = true
  runtime.documentTabs.allowsClosing = true
  runtime.documentTabs.allowsTabReordering = true
  runtime.documentTabs.setHuggingPriority(nk.LayoutPriorityRequired, nk.laVertical)
  runtime.documentTabs.setCompressionPriority(nk.LayoutPriorityRequired, nk.laVertical)

  runtime.editor.fontName = runtime.config.fontTypeface
  runtime.editor.fontSize = runtime.config.fontSize
  runtime.editor.padding = 0.0'f32
  runtime.editor.rawEventPolicy = nk.initMonoTextRawEventPolicy(
    forwardedEvents = nk.AllMonoTextRawEvents, capturedEvents = nk.AllMonoTextRawEvents
  )
  runtime.editor.rawEventHandler = proc(event: nk.MonoTextRawEvent): bool =
    runtime.handleMonoTextRawEvent(event)
  runtime.editor.setHuggingPriority(nk.LayoutPriorityLow, nk.laVertical)
  runtime.editor.setCompressionPriority(nk.LayoutPriorityLow, nk.laVertical)

  runtime.layoutView.spacing = 0.0'f32
  runtime.layoutView.alignment = nk.svaFill
  runtime.layoutView.distribution = nk.svdFill
  runtime.layoutView.addArrangedSubview(runtime.documentTabs, runtime.editor)
  runtime.rootView.addSubview(runtime.layoutView)
  runtime.layoutView.pinEdges(
    toGuide = runtime.rootView.contentLayoutGuide(),
    edges = {nk.leLeft, nk.leTop, nk.leRight, nk.leBottom},
  )

  runtime.kitWindow.setContentView(runtime.rootView)
  runtime.app.addWindow(runtime.kitWindow)
  discard runtime.kitWindow.makeFirstResponder(runtime.editor)
  runtime.kitWindow.makeKeyAndOrderFront()

proc initGuiRuntime*(
    config: GuiConfig, testCfg: GuiTestConfig = GuiTestConfig()
): GuiRuntime =
  new(result)
  initResponder(result)
  discard result.withProtocol(NeonimDocumentTabsDelegate)
  result.config = config
  result.testCfg = testCfg
  result.appRunning = true
  result.scrollSpeedMultiplier = scrollSpeedMultiplierFromEnv()
  result.scrollDirectionInverted = scrollDirectionInvertedFromEnv()
  result.testStart = epochTime()
  let frame = nk.initRect(120.0'f32, 120.0'f32, 1000.0'f32, 700.0'f32)
  registerBundledTypeface(config.fontTypeface)
  registerBundledTypeface(config.defaultTypeface)
  registerBundledTypeface("HackNerdFont-Regular.ttf")
  registerBundledTypeface("Ubuntu.ttf")
  let typefaceId = loadTypeface(config.fontTypeface, [config.defaultTypeface])
  result.monoFont = FigFont(typefaceId: typefaceId, size: config.fontSize)
  result.modifiers = {}
  result.activeTab = -1
  result.nextTabId = 1
  result.cursorBlinkStart = epochTime()
  result.cursorBlinkRow = -1
  result.cursorBlinkCol = -1
  result.cursorBlinkModeIdx = -1
  result.cursorVisible = true
  result.baseMainDir = guessMainDir(config.nvimArgs)
  result.topBarHeight = TopBarHeight
  result.buildNimKitViews(frame)
  let nativeWindow = result.kitWindow.nativeWindowOrNil()
  if not nativeWindow.isNil:
    trySetWindowIcon(nativeWindow)
  let (cellW, cellH) = monoMetrics(result.monoFont)
  result.cellW = cellW
  result.cellH = cellH
  warn "mono metrics: ", cellW = cellW, cellH = cellH

  let runtime = result
  if not runtime.addProcessTab(runtime.baseMainDir, config.nvimArgs):
    raise newException(NeovimError, "failed to launch initial nvim process tab")
  runtime.syncEditorView()

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
