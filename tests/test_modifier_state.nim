import std/unittest

import figdraw/windyshim

import neonim/modifier_state

suite "modifier state":
  test "maps modifier buttons into modifier state":
    check modifierStateFromButtons(ButtonView({})) ==
      (ctrlDown: false, shiftDown: false, altDown: false, cmdDown: false)
    check modifierStateFromButtons(ButtonView({KeyLeftControl})) ==
      (ctrlDown: true, shiftDown: false, altDown: false, cmdDown: false)
    check modifierStateFromButtons(ButtonView({KeyRightShift})) ==
      (ctrlDown: false, shiftDown: true, altDown: false, cmdDown: false)
    check modifierStateFromButtons(ButtonView({KeyLeftAlt, KeyRightSuper})) ==
      (ctrlDown: false, shiftDown: false, altDown: true, cmdDown: true)

  test "treats left and right variants the same":
    check modifierStateFromButtons(ButtonView({KeyLeftControl})) ==
      modifierStateFromButtons(ButtonView({KeyRightControl}))
    check modifierStateFromButtons(ButtonView({KeyLeftShift})) ==
      modifierStateFromButtons(ButtonView({KeyRightShift}))
    check modifierStateFromButtons(ButtonView({KeyLeftAlt})) ==
      modifierStateFromButtons(ButtonView({KeyRightAlt}))
    check modifierStateFromButtons(ButtonView({KeyLeftSuper})) ==
      modifierStateFromButtons(ButtonView({KeyRightSuper}))
