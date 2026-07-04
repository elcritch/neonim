import std/[options, tables, unicode, unittest]

import chroma
import vmath
import figdraw/windowing/siwinshim as siwin

import neonim/gui_backend
import neonim/ui_linegrid

suite "gui backend helpers":
  test "mouse mappings and scroll actions":
    check mouseButtonToNvimButton(siwin.MouseButton.left) == "left"
    check mouseButtonToNvimButton(siwin.MouseButton.right) == "right"
    check mouseButtonToNvimButton(siwin.MouseButton.forward) == "x1"
    check multiClickToNvimInput(2, row = 2, col = 7) == "<2-LeftMouse><7,2>"
    check multiClickToNvimInput(3, row = 2, col = 7) == "<3-LeftMouse><7,2>"
    check multiClickToNvimInput(1, row = 2, col = 7) == ""

    check mouseModifierFlags(
      ModifierView({siwin.ModifierKey.control, siwin.ModifierKey.shift})
    ) == "CS"
    check mouseModifierFlags(
      ModifierView({siwin.ModifierKey.alt, siwin.ModifierKey.system})
    ) == "AD"

    check mouseScrollActions(vec2(0, 10)) == @["up"]
    check mouseScrollActions(vec2(0, -10)) == @["down"]
    check mouseScrollActions(vec2(10, 0)) == @["left"]
    check mouseScrollActions(vec2(-10, 0)) == @["right"]
    check mouseScrollActions(vec2(0, 10), invertDirection = true) == @["down"]
    check mouseScrollActions(vec2(10, 0), invertDirection = true) == @["right"]
    check mouseScrollActions(vec2(0, 10), speedMultiplier = 1.0'f32) == @["up"]
    check mouseScrollActions(vec2(0, 10), speedMultiplier = 3.0'f32) ==
      @["up", "up", "up"]
    check mouseScrollActions(merendaScrollDeltaToMouseScrollDelta(10.0'f32, 0.0'f32)) ==
      @["right"]
    check mouseScrollActions(merendaScrollDeltaToMouseScrollDelta(-10.0'f32, 0.0'f32)) ==
      @["left"]
    check mouseScrollActions(merendaScrollDeltaToMouseScrollDelta(0.0'f32, 10.0'f32)) ==
      @["up"]
    check mouseScrollActions(
      merendaScrollDeltaToMouseScrollDelta(10.0'f32, 0.0'f32), invertDirection = true
    ) == @["left"]

  test "keyboard shortcuts and text input mapping":
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

  test "color resolution handles highlight and cursor attrs":
    var state = initLineGridState(2, 4)
    state.colors.bg = rgba(0x10'u8, 0x20'u8, 0x30'u8, 255).color
    state.colors.fg = rgba(0xee'u8, 0xee'u8, 0xee'u8, 255).color

    let
      cellFg = rgba(0xaa'u8, 0xbb'u8, 0xcc'u8, 255).color
      cellBg = rgba(0x33'u8, 0x44'u8, 0x55'u8, 255).color
      reverseFg = rgba(0xdd'u8, 0xee'u8, 0xff'u8, 255).color
      cursorBg = rgba(0x22'u8, 0x44'u8, 0x66'u8, 255).color

    var hl = HlState(attrs: initTable[int64, HlAttr]())
    hl.attrs[7] = HlAttr(fg: some(cellFg), bg: some(cellBg), reverse: false)
    hl.attrs[8] = HlAttr(fg: some(reverseFg), bg: none(Color), reverse: true)
    hl.attrs[9] = HlAttr(fg: none(Color), bg: some(cursorBg), reverse: false)

    let colors = resolveCellColors(state, hl, 7)
    check colors.fg == cellFg
    check colors.bg == some(cellBg)

    let reversed = resolveCellColors(state, hl, 8)
    check reversed.fg == state.colors.bg
    check reversed.bg == some(reverseFg)

    var cursorStyle = defaultCursorStyle()
    cursorStyle.attrId = 9
    let cursor =
      resolveCursorCellColors(state, hl, Cell(text: "X", hlId: 7), cursorStyle)
    check cursor.fill == cursorBg
    check cursor.text == cellBg

    let defaultCursor =
      resolveCursorCellColors(state, hl, Cell(text: "X", hlId: 7), defaultCursorStyle())
    check defaultCursor.fill == cellFg
    check defaultCursor.text == cellBg

  test "panel highlight columns use window rects and split fallback":
    var state = initLineGridState(4, 20)
    state.cursorGrid = 7
    state.winRects[7] = GridRect(row: 1, col: 3, rows: 2, cols: 5)
    state.panelHighlightRow = 2
    state.panelHighlightCol = 10
    check state.panelHighlightColumns() == (startCol: 3, endColExclusive: 8)

    state.cursorGrid = 0
    for row in 0 ..< state.rows:
      state.cells[state.cellIndex(row, 6)].text = "│"
    check state.panelHighlightColumns() == (startCol: 7, endColExclusive: 20)

    state.panelHighlightRow = -1
    check state.panelHighlightColumns() == (startCol: 0, endColExclusive: 20)
