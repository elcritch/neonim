import std/unittest

import figdraw/windowing/siwinshim as siwin
import neonim/modifier_state

suite "modifier state":
  test "maps modifiers into modifier state":
    check modifierStateFromModifiers({}) ==
      (ctrlDown: false, shiftDown: false, altDown: false, cmdDown: false)
    check modifierStateFromModifiers({siwin.ModifierKey.control}) ==
      (ctrlDown: true, shiftDown: false, altDown: false, cmdDown: false)
    check modifierStateFromModifiers({siwin.ModifierKey.shift}) ==
      (ctrlDown: false, shiftDown: true, altDown: false, cmdDown: false)
    check modifierStateFromModifiers({siwin.ModifierKey.alt, siwin.ModifierKey.system}) ==
      (ctrlDown: false, shiftDown: false, altDown: true, cmdDown: true)

  test "modifier conversion is deterministic":
    let modifiers = {siwin.ModifierKey.control, siwin.ModifierKey.alt}
    check modifierStateFromModifiers(modifiers) ==
      (ctrlDown: true, shiftDown: false, altDown: true, cmdDown: false)
