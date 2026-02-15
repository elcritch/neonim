import std/[os, unicode, unittest, tables]

import figdraw/commons
import figdraw/common/fonttypes
import figdraw/fignodes

import neonim/gui_backend
import neonim/windowing_backend
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
    var foundCmdlineBg = false
    if 1.ZLevel in renders.layers:
      for node in renders.layers[1.ZLevel].nodes:
        if node.kind == nkRectangle and node.fill == state.colors.bg:
          let expectedBgY = 2 * cellH * (rows - 1).float32
          if abs(node.screenBox.y - expectedBgY) < 0.001'f32 and
              abs(node.screenBox.h - (2 * cellH)) < 0.001'f32:
            foundCmdlineBg = true
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
    check foundCmdlineBg
    let expectedY = cellH * (rows - 1).float32
    check abs(colonY - expectedY) < 0.001'f32

  test "mouse mappings and panel highlight overlay":
    check mouseButtonToNvimButton(MouseLeft) == "left"
    check mouseButtonToNvimButton(MouseRight) == "right"
    check mouseButtonToNvimButton(KeyA) == ""
    check multiClickToNvimInput(DoubleClick, row = 2, col = 7) == "<2-LeftMouse><7,2>"
    check multiClickToNvimInput(TripleClick, row = 2, col = 7) == "<3-LeftMouse><7,2>"
    check multiClickToNvimInput(MouseLeft, row = 2, col = 7) == ""

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
    check uiScaleDeltaForShortcut(KeyEqual, ButtonView({KeyLeftSuper, KeyLeftShift})) ==
      UiScaleStep
    check uiScaleDeltaForShortcut(KeyEqual, ButtonView({KeyLeftSuper})) == UiScaleStep
    check uiScaleDeltaForShortcut(KeyMinus, ButtonView({KeyRightSuper})) == -UiScaleStep
    check uiScaleDeltaForShortcut(NumpadAdd, ButtonView({KeyLeftSuper})) == UiScaleStep
    check uiScaleDeltaForShortcut(NumpadSubtract, ButtonView({KeyLeftSuper})) ==
      -UiScaleStep
    check uiScaleDeltaForShortcut(KeyEqual, ButtonView({})) == 0.0'f32
    check uiScaleDeltaForShortcut(KeyEqual, ButtonView({KeyLeftShift})) == 0.0'f32
    check uiScaleDeltaForShortcut(KeyMinus, ButtonView({})) == 0.0'f32
    check keyToNvimInput(KeyF, ctrlDown = false, altDown = true) == "<A-f>"
    check keyToNvimInput(KeyB, ctrlDown = false, altDown = true) == "<A-b>"
    check keyToNvimInput(KeyLeft, ctrlDown = false, altDown = true) == "<A-Left>"
    check keyToNvimInput(KeyEnter, ctrlDown = false, altDown = true) == "<A-CR>"
    check keyToNvimInput(KeyB, ctrlDown = true, altDown = true) == "<A-C-b>"
    check runeToNvimInput(Rune('<')) == "<LT>"
    check runeToNvimInput(Rune('a')) == "a"
    check cmdShortcutAction(KeyC) == csaCopy
    check cmdShortcutAction(KeyV) == csaPaste
    check cmdShortcutAction(KeyX) == csaNone
    check isVisualLikeMode("v")
    check isVisualLikeMode("V")
    check isVisualLikeMode($char(0x16))
    check not isVisualLikeMode("n")
    check not isVisualLikeMode("")

    let monoFont = testMonoFont()
    let (cellW, cellH) = monoMetrics(monoFont)
    var state = initLineGridState(4, 20)
    state.cursorRow = -1
    state.cursorCol = -1
    state.cursorGrid = 7
    state.winRects[7] = GridRect(row: 1, col: 3, rows: 2, cols: 5)
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
            abs(node.screenBox.x - (3 * cellW)) < 0.001'f32 and
            abs(node.screenBox.w - (5 * cellW)) < 0.001'f32 and
            abs(node.screenBox.y - (2 * 2.0'f32 * cellH)) < 0.001'f32 and
            abs(node.screenBox.h - (2 * cellH)) < 0.001'f32
          if foundPanel:
            break
    check foundPanel

  test "panel highlight falls back to split-bounded width in single grid":
    let monoFont = testMonoFont()
    let (cellW, cellH) = monoMetrics(monoFont)
    var state = initLineGridState(4, 20)
    state.cursorRow = -1
    state.cursorCol = -1
    state.cursorGrid = 0
    state.panelHighlightRow = 2
    state.panelHighlightCol = 10
    for r in 0 ..< state.rows:
      state.cells[state.cellIndex(r, 6)].text = "│"
    let hl = HlState(attrs: initTable[int64, HlAttr]())
    let w = cellW * 20.0'f32
    let h = cellH * 8.0'f32
    let renders = makeRenderTree(w, h, monoFont, state, hl, cellW, cellH)

    var foundPanel = false
    if 1.ZLevel in renders.layers:
      for node in renders.layers[1.ZLevel].nodes:
        if node.kind == nkRectangle and node.fill == PanelHighlightFill:
          foundPanel =
            abs(node.screenBox.x - (7 * cellW)) < 0.001'f32 and
            abs(node.screenBox.w - (13 * cellW)) < 0.001'f32 and
            abs(node.screenBox.y - (2 * 2.0'f32 * cellH)) < 0.001'f32 and
            abs(node.screenBox.h - (2 * cellH)) < 0.001'f32
          if foundPanel:
            break
    check foundPanel
