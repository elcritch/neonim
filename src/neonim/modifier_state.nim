import figdraw/windowing/siwinshim as siwin

type ModifierState* = tuple[ctrlDown, shiftDown, altDown, cmdDown: bool]

proc modifierStateFromModifiers*(modifiers: set[siwin.ModifierKey]): ModifierState =
  (
    ctrlDown: siwin.ModifierKey.control in modifiers,
    shiftDown: siwin.ModifierKey.shift in modifiers,
    altDown: siwin.ModifierKey.alt in modifiers,
    cmdDown: siwin.ModifierKey.system in modifiers,
  )

when defined(macosx):
  type
    CGEventRef = pointer
    CGEventFlags = uint64

  proc CGEventCreate(
    source: pointer
  ): CGEventRef {.importc, header: "<CoreGraphics/CoreGraphics.h>".}

  proc CGEventGetFlags(
    event: CGEventRef
  ): CGEventFlags {.importc, header: "<CoreGraphics/CoreGraphics.h>".}

  proc CFRelease(cf: pointer) {.importc, header: "<CoreFoundation/CoreFoundation.h>".}

  const
    CgShiftMask = 0x00020000'u64
    CgCtrlMask = 0x00040000'u64
    CgAltMask = 0x00080000'u64
    CgCmdMask = 0x00100000'u64

  proc tryModifierStateFromCgEvent(state: var ModifierState): bool =
    let ev = CGEventCreate(nil)
    if ev == nil:
      return false
    let flags = CGEventGetFlags(ev)
    CFRelease(ev)
    state.ctrlDown = (flags and CgCtrlMask) != 0
    state.shiftDown = (flags and CgShiftMask) != 0
    state.altDown = (flags and CgAltMask) != 0
    state.cmdDown = (flags and CgCmdMask) != 0
    true

proc currentModifierState*(modifiers: set[siwin.ModifierKey]): ModifierState =
  result = modifierStateFromModifiers(modifiers)
  when defined(macosx):
    discard tryModifierStateFromCgEvent(result)
