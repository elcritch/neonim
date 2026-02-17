import ./input_buttons

type ModifierState* = tuple[ctrlDown, shiftDown, altDown, cmdDown: bool]

proc modifierStateFromButtons*(buttons: ButtonView): ModifierState =
  (
    ctrlDown:
      buttonPressed(buttons, KeyLeftControl) or buttonPressed(buttons, KeyRightControl),
    shiftDown:
      buttonPressed(buttons, KeyLeftShift) or buttonPressed(buttons, KeyRightShift),
    altDown: buttonPressed(buttons, KeyLeftAlt) or buttonPressed(buttons, KeyRightAlt),
    cmdDown:
      buttonPressed(buttons, KeyLeftSuper) or buttonPressed(buttons, KeyRightSuper),
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

proc currentModifierState*(buttons: ButtonView): ModifierState =
  result = modifierStateFromButtons(buttons)
  when defined(macosx):
    discard tryModifierStateFromCgEvent(result)
