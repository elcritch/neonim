import std/[options, os, unicode, unittest, tables]

import figdraw/commons
import figdraw/common/fonttypes
import figdraw/fignodes
import figdraw/windowing/siwinshim as siwin

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
    var foundCmdlineBg = false
    if 1.ZLevel in renders.layers:
      for node in renders.layers[1.ZLevel].nodes:
        if node.kind == nkRectangle and node.fill.kind == flColor and
            node.fill.color == rgba(state.colors.bg):
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
                node.textLayout.spanColors[0].kind == flColor and
                node.textLayout.spanColors[0].color == rgba(state.colors.fg)
              break
        if foundColon:
          break
    check foundColon
    check colonColorOk
    check foundCmdlineBg
    let expectedY = cellH * (rows - 1).float32
    check abs(colonY - expectedY) < 0.001'f32

  test "mouse mappings and panel highlight overlay":
    check mouseButtonToNvimButton(siwin.MouseButton.left) == "left"
    check mouseButtonToNvimButton(siwin.MouseButton.right) == "right"
    check mouseButtonToNvimButton(siwin.MouseButton.forward) == "x1"
    check multiClickToNvimInput(2, row = 2, col = 7) == "<2-LeftMouse><7,2>"
    check multiClickToNvimInput(3, row = 2, col = 7) == "<3-LeftMouse><7,2>"
    check multiClickToNvimInput(1, row = 2, col = 7) == ""

    check mouseDragButtonToNvimButton(MouseButtonView({siwin.MouseButton.left})) ==
      "left"
    check mouseDragButtonToNvimButton(MouseButtonView({siwin.MouseButton.middle})) ==
      "middle"
    check mouseDragButtonToNvimButton(MouseButtonView({})) == ""

    check mouseModifierFlags(
      ModifierView({siwin.ModifierKey.control, siwin.ModifierKey.shift})
    ) == "CS"
    check mouseModifierFlags(
      ModifierView({siwin.ModifierKey.alt, siwin.ModifierKey.system})
    ) == "AD"

    check mouseGridCell(vec2(0, 0), rows = 10, cols = 20, cellW = 8, cellH = 4) ==
      (row: 0, col: 0)
    check mouseGridCell(vec2(79, 15), rows = 10, cols = 20, cellW = 8, cellH = 4) ==
      (row: 1, col: 9)
    check mouseGridCell(vec2(999, 999), rows = 10, cols = 20, cellW = 8, cellH = 4) ==
      (row: 9, col: 19)
    check inputPosToLogical(vec2(120, 60), usesBackingPixels = false, inputScale = 2.0) ==
      vec2(120, 60)
    check inputPosToLogical(vec2(120, 60), usesBackingPixels = true, inputScale = 2.0) ==
      vec2(60, 30)

    check mouseScrollActions(vec2(0, 10)) == @["up"]
    check mouseScrollActions(vec2(0, -10)) == @["down"]
    check mouseScrollActions(vec2(10, 0)) == @["left"]
    check mouseScrollActions(vec2(-10, 0)) == @["right"]
    check mouseScrollActions(vec2(0, 10), invertDirection = true) == @["down"]
    check mouseScrollActions(vec2(10, 0), invertDirection = true) == @["right"]
    check mouseScrollActions(vec2(0, 10), speedMultiplier = 1.0'f32) == @["up"]
    check mouseScrollActions(vec2(0, 10), speedMultiplier = 3.0'f32) ==
      @["up", "up", "up"]
    check fontSizeDeltaForShortcut(
      siwin.Key.equal, ModifierView({siwin.ModifierKey.system, siwin.ModifierKey.shift})
    ) == FontSizeStep
    check fontSizeDeltaForShortcut(
      siwin.Key.equal, ModifierView({siwin.ModifierKey.system})
    ) == FontSizeStep
    check fontSizeDeltaForShortcut(
      siwin.Key.minus, ModifierView({siwin.ModifierKey.system})
    ) == -FontSizeStep
    check fontSizeDeltaForShortcut(
      siwin.Key.add, ModifierView({siwin.ModifierKey.system})
    ) == FontSizeStep
    check fontSizeDeltaForShortcut(
      siwin.Key.subtract, ModifierView({siwin.ModifierKey.system})
    ) == -FontSizeStep
    check fontSizeDeltaForShortcut(
      siwin.Key.equal,
      ModifierView({siwin.ModifierKey.control, siwin.ModifierKey.shift}),
    ) == FontSizeStep
    check fontSizeDeltaForShortcut(
      siwin.Key.equal, ModifierView({siwin.ModifierKey.control})
    ) == FontSizeStep
    check fontSizeDeltaForShortcut(
      siwin.Key.minus, ModifierView({siwin.ModifierKey.control})
    ) == -FontSizeStep
    check fontSizeDeltaForShortcut(
      siwin.Key.add, ModifierView({siwin.ModifierKey.control})
    ) == FontSizeStep
    check fontSizeDeltaForShortcut(
      siwin.Key.subtract, ModifierView({siwin.ModifierKey.control})
    ) == -FontSizeStep
    check fontSizeDeltaForShortcut(siwin.Key.equal, ModifierView({})) == 0.0'f32
    check fontSizeDeltaForShortcut(
      siwin.Key.equal, ModifierView({siwin.ModifierKey.shift})
    ) == 0.0'f32
    check fontSizeDeltaForShortcut(siwin.Key.minus, ModifierView({})) == 0.0'f32
    check keyToNvimInput(siwin.Key.f, ctrlDown = false, altDown = true) == "<A-f>"
    check keyToNvimInput(siwin.Key.b, ctrlDown = false, altDown = true) == "<A-b>"
    check keyToNvimInput(siwin.Key.left, ctrlDown = false, altDown = true) == "<A-Left>"
    check keyToNvimInput(siwin.Key.enter, ctrlDown = false, altDown = true) == "<A-CR>"
    check keyToNvimInput(siwin.Key.b, ctrlDown = true, altDown = true) == "<A-C-b>"
    check runeToNvimInput(Rune('<')) == "<LT>"
    check runeToNvimInput(Rune('a')) == "a"

    check cmdShortcutAction(siwin.Key.c) == csaCopy
    check cmdShortcutAction(siwin.Key.v) == csaPaste
    check cmdShortcutAction(siwin.Key.x) == csaNone
    when defined(macosx):
      check clipboardShortcutModifierDown(ModifierView({siwin.ModifierKey.system}))
      check not clipboardShortcutModifierDown(ModifierView({siwin.ModifierKey.control}))
    else:
      check clipboardShortcutModifierDown(
        ModifierView({siwin.ModifierKey.control, siwin.ModifierKey.shift})
      )
      check not clipboardShortcutModifierDown(ModifierView({siwin.ModifierKey.control}))
      check not clipboardShortcutModifierDown(ModifierView({siwin.ModifierKey.shift}))
      check not clipboardShortcutModifierDown(ModifierView({siwin.ModifierKey.system}))
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
        if node.kind == nkRectangle and node.fill.kind == flColor and
            node.fill.color == rgba(PanelHighlightFill):
          foundPanel =
            abs(node.screenBox.x - (3 * cellW)) < 0.001'f32 and
            abs(node.screenBox.w - (5 * cellW)) < 0.001'f32 and
            abs(node.screenBox.y - (2 * 2.0'f32 * cellH)) < 0.001'f32 and
            abs(node.screenBox.h - (2 * cellH)) < 0.001'f32
          if foundPanel:
            break
    check foundPanel

  test "cursor renderer uses mode_info_set shape and highlight color":
    let monoFont = testMonoFont()
    let (cellW, cellH) = monoMetrics(monoFont)
    let rows = 3
    let cols = 6
    let w = cellW * cols.float32
    let h = cellH * rows.float32
    var state = initLineGridState(rows, cols)
    state.cursorRow = 1
    state.cursorCol = 2
    state.cursorStyleEnabled = true
    state.cursorStyles =
      @[
        CursorStyle(
          shape: csVertical,
          cellPercentage: 25,
          blinkwait: 0,
          blinkon: 0,
          blinkoff: 0,
          attrId: 5,
          attrIdLm: 0,
          shortName: "i",
          name: "insert",
        )
      ]
    state.currentModeIdx = 0
    let cursorBg = rgba(0x22'u8, 0x44'u8, 0x66'u8, 255).color
    var hl = HlState(attrs: initTable[int64, HlAttr]())
    hl.attrs[5] = HlAttr(fg: none(Color), bg: some(cursorBg), reverse: false)

    let renders = makeRenderTree(w, h, monoFont, state, hl, cellW, cellH)

    var foundCursor = false
    if 1.ZLevel in renders.layers:
      for node in renders.layers[1.ZLevel].nodes:
        if node.kind == nkRectangle and node.fill.kind == flColor and
            node.fill.color == rgba(cursorBg):
          foundCursor =
            abs(node.screenBox.x - (2 * cellW)) < 0.001'f32 and
            abs(node.screenBox.y - (1 * 2.0'f32 * cellH)) < 0.001'f32 and
            abs(node.screenBox.w - max(1.0'f32, cellW * 0.25'f32)) < 0.001'f32 and
            abs(node.screenBox.h - (2 * cellH)) < 0.001'f32
          if foundCursor:
            break
    check foundCursor

  test "block cursor swaps cell colors and redraws cell text":
    let monoFont = testMonoFont()
    let (cellW, cellH) = monoMetrics(monoFont)
    var state = initLineGridState(2, 4)
    state.colors.bg = rgba(0x10'u8, 0x20'u8, 0x30'u8, 255).color
    state.cursorRow = 0
    state.cursorCol = 1
    state.cursorStyleEnabled = true
    state.cursorStyles = @[defaultCursorStyle()]
    state.currentModeIdx = 0
    state.cells[state.cellIndex(0, 1)].text = "X"
    state.cells[state.cellIndex(0, 1)].hlId = 7
    let cellFg = rgba(0xaa'u8, 0xbb'u8, 0xcc'u8, 255).color
    let cellBg = rgba(0x33'u8, 0x44'u8, 0x55'u8, 255).color
    var hl = HlState(attrs: initTable[int64, HlAttr]())
    hl.attrs[7] = HlAttr(fg: some(cellFg), bg: some(cellBg), reverse: false)

    let renders = makeRenderTree(
      cellW * 4.0'f32, cellH * 2.0'f32, monoFont, state, hl, cellW, cellH
    )

    var foundCursorBg = false
    var foundCursorText = false
    if 1.ZLevel in renders.layers:
      for node in renders.layers[1.ZLevel].nodes:
        if node.kind == nkRectangle and node.fill.kind == flColor and
            node.fill.color == rgba(cellFg):
          foundCursorBg = true
        if node.kind == nkText and node.fill.kind == flColor and
            node.fill.color == rgba(cellBg):
          for r in node.textLayout.runes:
            if r == Rune('X'):
              foundCursorText = true
              break
    check foundCursorBg
    check foundCursorText

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
        if node.kind == nkRectangle and node.fill.kind == flColor and
            node.fill.color == rgba(PanelHighlightFill):
          foundPanel =
            abs(node.screenBox.x - (7 * cellW)) < 0.001'f32 and
            abs(node.screenBox.w - (13 * cellW)) < 0.001'f32 and
            abs(node.screenBox.y - (2 * 2.0'f32 * cellH)) < 0.001'f32 and
            abs(node.screenBox.h - (2 * cellH)) < 0.001'f32
          if foundPanel:
            break
    check foundPanel
