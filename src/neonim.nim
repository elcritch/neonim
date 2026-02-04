## Neonim - Neovim GUI backend in Nim.
##
import std/[streams, os, strutils]

import vmath
import msgpack4nim

import figdraw/[commons, fignodes, figrender, windyshim]
import ./neonim/[types, rpc, nvim_client, ui_linegrid, gui_backend]

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

proc runWindyFigdrawGui*(config: GuiConfig) =
  when not defined(emscripten):
    setFigDataDir(getCurrentDir() / "data")

  var app_running = true
  let size = ivec2(1000, 700)
  let title = "Neonim"
  let typefaceId = loadTypeface(config.fontTypeface)
  let monoFont = UiFont(typefaceId: typefaceId, size: config.fontSize)
  let window = newWindyWindow(size = size, fullscreen = false, title = title)
  window.runeInputEnabled = true

  if getEnv("HDI") != "":
    setFigUiScale getEnv("HDI").parseFloat()
  else:
    setFigUiScale window.contentScale()
  if size != size.scaled():
    window.size = size.scaled()

  let renderer = newFigRenderer(atlasSize = 2048)

  var client = newNeovimClient()
  client.start(config.nvimCmd, config.nvimArgs)
  discard client.discoverMetadata()

  var hl = HlState(attrs: initTable[int64, HlAttr]())
  let sz = window.logicalSize()
  let (cellW, cellH) = monoMetrics(monoFont)

  var (rows, cols) = computeGridSize(sz, cellW, cellH)
  var state = initLineGridState(rows, cols)

  client.onNotification = proc(methodName: string, params: RpcParamsBuffer) =
    if methodName == "redraw":
      handleRedraw(state, hl, params)

  block attachUi:
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

  proc redraw() =
    let sz = window.logicalSize()
    var renders = makeRenderTree(sz.x, sz.y, monoFont, state, cellW, cellH)
    renderer.renderFrame(renders, sz)
    when not UseMetalBackend:
      window.swapBuffers()

  proc tryResizeUi() =
    let sz = window.logicalSize()
    let newSz = computeGridSize(sz, cellW, cellH)
    if newSz.rows != state.rows or newSz.cols != state.cols:
      discard
        client.request("nvim_ui_try_resize", rpcPackParams(newSz.cols, newSz.rows))

  window.onCloseRequest = proc() =
    app_running = false
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
    while app_running:
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
    )
  )
