import figdraw/windowing/siwinshim as siwin

const NeonimWindowBackendName* = "siwin"

type
  Button* = enum
    KeyA
    KeyB
    KeyC
    KeyD
    KeyE
    KeyF
    KeyG
    KeyH
    KeyI
    KeyJ
    KeyK
    KeyL
    KeyM
    KeyN
    KeyO
    KeyP
    KeyQ
    KeyR
    KeyS
    KeyT
    KeyU
    KeyV
    KeyW
    KeyX
    KeyY
    KeyZ
    Key0
    Key1
    Key2
    Key3
    Key4
    Key5
    Key6
    Key7
    Key8
    Key9
    KeySpace
    KeyBacktick
    KeyMinus
    KeyEqual
    KeyLeftBracket
    KeyRightBracket
    KeyBackslash
    KeySemicolon
    KeyApostrophe
    KeyComma
    KeyPeriod
    KeySlash
    KeyEnter
    KeyBackspace
    KeyTab
    KeyEscape
    KeyUp
    KeyDown
    KeyLeft
    KeyRight
    KeyDelete
    KeyHome
    KeyEnd
    KeyPageUp
    KeyPageDown
    NumpadAdd
    NumpadSubtract
    KeyLeftControl
    KeyRightControl
    KeyLeftShift
    KeyRightShift
    KeyLeftAlt
    KeyRightAlt
    KeyLeftSuper
    KeyRightSuper
    MouseLeft
    MouseRight
    MouseMiddle
    MouseButton4
    MouseButton5
    DoubleClick
    TripleClick
    QuadrupleClick

  ButtonView* = set[Button]

proc mapKey*(key: siwin.Key): tuple[ok: bool, button: Button] =
  case key
  of siwin.Key.a:
    (true, KeyA)
  of siwin.Key.b:
    (true, KeyB)
  of siwin.Key.c:
    (true, KeyC)
  of siwin.Key.d:
    (true, KeyD)
  of siwin.Key.e:
    (true, KeyE)
  of siwin.Key.f:
    (true, KeyF)
  of siwin.Key.g:
    (true, KeyG)
  of siwin.Key.h:
    (true, KeyH)
  of siwin.Key.i:
    (true, KeyI)
  of siwin.Key.j:
    (true, KeyJ)
  of siwin.Key.k:
    (true, KeyK)
  of siwin.Key.l:
    (true, KeyL)
  of siwin.Key.m:
    (true, KeyM)
  of siwin.Key.n:
    (true, KeyN)
  of siwin.Key.o:
    (true, KeyO)
  of siwin.Key.p:
    (true, KeyP)
  of siwin.Key.q:
    (true, KeyQ)
  of siwin.Key.r:
    (true, KeyR)
  of siwin.Key.s:
    (true, KeyS)
  of siwin.Key.t:
    (true, KeyT)
  of siwin.Key.u:
    (true, KeyU)
  of siwin.Key.v:
    (true, KeyV)
  of siwin.Key.w:
    (true, KeyW)
  of siwin.Key.x:
    (true, KeyX)
  of siwin.Key.y:
    (true, KeyY)
  of siwin.Key.z:
    (true, KeyZ)
  of siwin.Key.n0:
    (true, Key0)
  of siwin.Key.n1:
    (true, Key1)
  of siwin.Key.n2:
    (true, Key2)
  of siwin.Key.n3:
    (true, Key3)
  of siwin.Key.n4:
    (true, Key4)
  of siwin.Key.n5:
    (true, Key5)
  of siwin.Key.n6:
    (true, Key6)
  of siwin.Key.n7:
    (true, Key7)
  of siwin.Key.n8:
    (true, Key8)
  of siwin.Key.n9:
    (true, Key9)
  of siwin.Key.space:
    (true, KeySpace)
  of siwin.Key.tilde:
    (true, KeyBacktick)
  of siwin.Key.minus:
    (true, KeyMinus)
  of siwin.Key.equal:
    (true, KeyEqual)
  of siwin.Key.lbracket:
    (true, KeyLeftBracket)
  of siwin.Key.rbracket:
    (true, KeyRightBracket)
  of siwin.Key.backslash:
    (true, KeyBackslash)
  of siwin.Key.semicolon:
    (true, KeySemicolon)
  of siwin.Key.quote:
    (true, KeyApostrophe)
  of siwin.Key.comma:
    (true, KeyComma)
  of siwin.Key.dot:
    (true, KeyPeriod)
  of siwin.Key.slash:
    (true, KeySlash)
  of siwin.Key.enter:
    (true, KeyEnter)
  of siwin.Key.backspace:
    (true, KeyBackspace)
  of siwin.Key.tab:
    (true, KeyTab)
  of siwin.Key.escape:
    (true, KeyEscape)
  of siwin.Key.up:
    (true, KeyUp)
  of siwin.Key.down:
    (true, KeyDown)
  of siwin.Key.left:
    (true, KeyLeft)
  of siwin.Key.right:
    (true, KeyRight)
  of siwin.Key.del:
    (true, KeyDelete)
  of siwin.Key.home:
    (true, KeyHome)
  of siwin.Key.End:
    (true, KeyEnd)
  of siwin.Key.pageUp:
    (true, KeyPageUp)
  of siwin.Key.pageDown:
    (true, KeyPageDown)
  of siwin.Key.add:
    (true, NumpadAdd)
  of siwin.Key.subtract:
    (true, NumpadSubtract)
  of siwin.Key.lcontrol:
    (true, KeyLeftControl)
  of siwin.Key.rcontrol:
    (true, KeyRightControl)
  of siwin.Key.lshift:
    (true, KeyLeftShift)
  of siwin.Key.rshift:
    (true, KeyRightShift)
  of siwin.Key.lalt:
    (true, KeyLeftAlt)
  of siwin.Key.ralt:
    (true, KeyRightAlt)
  of siwin.Key.lsystem:
    (true, KeyLeftSuper)
  of siwin.Key.rsystem:
    (true, KeyRightSuper)
  else:
    (false, KeyA)

proc mapMouse*(button: siwin.MouseButton): tuple[ok: bool, button: Button] =
  case button
  of siwin.MouseButton.left:
    (true, MouseLeft)
  of siwin.MouseButton.right:
    (true, MouseRight)
  of siwin.MouseButton.middle:
    (true, MouseMiddle)
  of siwin.MouseButton.forward:
    (true, MouseButton4)
  of siwin.MouseButton.backward:
    (true, MouseButton5)

proc buttonPressed*(buttons: ButtonView, button: Button): bool =
  button in buttons
