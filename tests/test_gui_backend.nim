import std/[os, unicode, unittest, tables]

import figdraw/commons
import figdraw/common/fonttypes
import figdraw/fignodes

import neonim/gui_backend
import neonim/ui_linegrid

suite "gui backend renders":
  test "cmdline colon creates text fig":
    let dataDir = getCurrentDir() / "data"
    check fileExists(dataDir / "HackNerdFont-Regular.ttf")
    setFigDataDir(dataDir)

    let fontId = loadTypeface("HackNerdFont-Regular.ttf")
    let monoFont = UiFont(typefaceId: fontId, size: 16.0'f32)
    let (cellW, cellH) = monoMetrics(monoFont)

    let cols = 20
    let rows = 10
    let w = cellW * cols.float32
    let h = cellH * rows.float32
    var state = initLineGridState(rows, cols)
    state.cmdlineActive = true
    state.cmdlineText = ":"

    let hl = HlState(attrs: initTable[int64, HlAttr]())
    let renders = makeRenderTree(w, h, monoFont, state, hl, cellW, cellH)

    var foundColon = false
    var colonY = 0.0'f32
    if 1.ZLevel in renders.layers:
      for node in renders.layers[1.ZLevel].nodes:
        if node.kind == nkText:
          for r in node.textLayout.runes:
            if r == Rune(':'):
              foundColon = true
              colonY = node.screenBox.y
              break
        if foundColon:
          break
    check foundColon
    let expectedY = cellH * (rows - 1).float32
    check abs(colonY - expectedY) < 0.001'f32
