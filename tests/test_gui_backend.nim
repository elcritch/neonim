import std/[os, unicode, unittest, tables]

import figdraw/commons
import figdraw/common/fonttypes
import figdraw/fignodes
import figdraw/windyshim

import neonim/gui_backend
import neonim/ui_linegrid

var cachedFontId: FontId = FontId(0)

proc testMonoFont(size = 16.0'f32): FigFont =
  if cachedFontId == FontId(0):
    let dataDir = getCurrentDir() / "data"
    doAssert fileExists(dataDir / "HackNerdFont-Regular.ttf")
    setFigDataDir(dataDir)
    cachedFontId = loadTypeface("HackNerdFont-Regular.ttf")
  FigFont(typefaceId: cachedFontId, size: size)

suite "gui backend renders":
  test "cmdline colon creates text fig":
    let monoFont = testMonoFont()
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
    var colonColorOk = false
    if 1.ZLevel in renders.layers:
      for node in renders.layers[1.ZLevel].nodes:
        if node.kind == nkText:
          for r in node.textLayout.runes:
            if r == Rune(':'):
              foundColon = true
              colonY = node.screenBox.y
              colonColorOk =
                node.textLayout.spanColors.len == 1 and
                node.textLayout.spanColors[0] == state.colors.fg
              break
        if foundColon:
          break
    check foundColon
    check colonColorOk
    let expectedY = cellH * (rows - 1).float32
    check abs(colonY - expectedY) < 0.001'f32

  test "mouse mappings and panel highlight overlay":
    check mouseButtonToNvimButton(MouseLeft) == "left"
    check mouseButtonToNvimButton(MouseRight) == "right"
    check mouseButtonToNvimButton(KeyA) == ""

    check mouseDragButtonToNvimButton(ButtonView({MouseLeft})) == "left"
    check mouseDragButtonToNvimButton(ButtonView({MouseMiddle})) == "middle"
    check mouseDragButtonToNvimButton(ButtonView({})) == ""

    check mouseModifierFlags(ButtonView({KeyLeftControl, KeyLeftShift})) == "CS"
    check mouseModifierFlags(ButtonView({KeyRightAlt, KeyRightSuper})) == "AD"

    check mouseGridCell(vec2(0, 0), rows = 10, cols = 20, cellW = 8, cellH = 4) ==
      (row: 0, col: 0)
    check mouseGridCell(vec2(79, 15), rows = 10, cols = 20, cellW = 8, cellH = 4) ==
      (row: 1, col: 9)
    check mouseGridCell(vec2(999, 999), rows = 10, cols = 20, cellW = 8, cellH = 4) ==
      (row: 9, col: 19)

    check mouseScrollActions(vec2(0, 10)) == @["up"]
    check mouseScrollActions(vec2(0, -10)) == @["down"]
    check mouseScrollActions(vec2(10, 0)) == @["left"]
    check mouseScrollActions(vec2(-10, 0)) == @["right"]

    let monoFont = testMonoFont()
    let (cellW, cellH) = monoMetrics(monoFont)
    var state = initLineGridState(4, 20)
    state.cursorRow = -1
    state.cursorCol = -1
    state.panelHighlightRow = 2
    let hl = HlState(attrs: initTable[int64, HlAttr]())
    let w = cellW * 20.0'f32
    let h = cellH * 8.0'f32
    let renders = makeRenderTree(w, h, monoFont, state, hl, cellW, cellH)

    var foundPanel = false
    if 1.ZLevel in renders.layers:
      for node in renders.layers[1.ZLevel].nodes:
        if node.kind == nkRectangle and node.fill == PanelHighlightFill:
          foundPanel =
            abs(node.screenBox.y - (2 * 2.0'f32 * cellH)) < 0.001'f32 and
            abs(node.screenBox.h - (2 * cellH)) < 0.001'f32
          if foundPanel:
            break
    check foundPanel
