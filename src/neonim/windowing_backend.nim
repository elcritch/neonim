import std/unicode

import vmath
import pkg/pixie
import siwin/clipboards
import siwin/colorutils
import figdraw/figrender
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
  NeonimRenderBackend* = siwin.SiwinRenderBackend

  Window* = ref object
    raw*: siwin.Window
    started: bool
    runeInputEnabled*: bool
    down*: ButtonView
    lastScroll*: Vec2
    onCloseRequest*: proc()
    onResize*: proc()
    onMouseMove*: proc()
    onScroll*: proc()
    onRune*: proc(r: Rune)
    onButtonPress*: proc(button: Button)
    onButtonRelease*: proc(button: Button)

var clipboardWindow {.threadvar.}: Window

proc mapKey(key: siwin.Key): tuple[ok: bool, button: Button] =
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

proc mapMouse(button: siwin.MouseButton): tuple[ok: bool, button: Button] =
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

proc installHandlers(window: Window) =
  window.raw.eventsHandler.onClose = proc(_: siwin.CloseEvent) =
    if window.onCloseRequest != nil:
      window.onCloseRequest()

  window.raw.eventsHandler.onResize = proc(_: siwin.ResizeEvent) =
    if window.onResize != nil:
      window.onResize()

  window.raw.eventsHandler.onMouseMove = proc(_: siwin.MouseMoveEvent) =
    if window.onMouseMove != nil:
      window.onMouseMove()

  window.raw.eventsHandler.onScroll = proc(e: siwin.ScrollEvent) =
    window.lastScroll = vec2(e.deltaX.float32, e.delta.float32)
    if window.onScroll != nil:
      window.onScroll()

  window.raw.eventsHandler.onTextInput = proc(e: siwin.TextInputEvent) =
    if not window.runeInputEnabled:
      return
    if window.onRune == nil:
      return
    for r in e.text.runes:
      window.onRune(r)

  window.raw.eventsHandler.onKey = proc(e: siwin.KeyEvent) =
    let (ok, button) = mapKey(e.key)
    if not ok:
      return
    if e.pressed:
      window.down.incl(button)
      if window.onButtonPress != nil:
        window.onButtonPress(button)
    else:
      window.down.excl(button)
      if window.onButtonRelease != nil:
        window.onButtonRelease(button)

  window.raw.eventsHandler.onMouseButton = proc(e: siwin.MouseButtonEvent) =
    let (ok, button) = mapMouse(e.button)
    if not ok:
      return
    if e.pressed:
      window.down.incl(button)
      if window.onButtonPress != nil:
        window.onButtonPress(button)
    else:
      window.down.excl(button)
      if window.onButtonRelease != nil:
        window.onButtonRelease(button)

  window.raw.eventsHandler.onClick = proc(e: siwin.ClickEvent) =
    if not e.double:
      return
    if window.onButtonPress != nil:
      window.onButtonPress(DoubleClick)

proc newNeonimWindow*(size: IVec2, fullscreen = false, title = "FigDraw"): Window =
  new(result)
  result.raw = siwin.newSiwinWindow(size = size, fullscreen = fullscreen, title = title)
  result.runeInputEnabled = true
  result.down = {}
  result.lastScroll = vec2(0, 0)
  result.installHandlers()
  clipboardWindow = result

proc backendWindow*(window: Window): siwin.Window =
  window.raw

proc setupBackend*(renderer: FigRenderer[NeonimRenderBackend], window: siwin.Window) =
  siwin.setupBackend(renderer, window)

proc beginFrame*(renderer: FigRenderer[NeonimRenderBackend]) =
  siwin.beginFrame(renderer)

proc endFrame*(renderer: FigRenderer[NeonimRenderBackend]) =
  siwin.endFrame(renderer)

proc pollWindowEvents*(window: Window) =
  if window.isNil or window.raw.isNil:
    return
  if not window.started:
    window.raw.firstStep(makeVisible = true)
    window.started = true
  if window.raw.opened:
    window.raw.step()

proc logicalSize*(window: Window): Vec2 =
  siwin.logicalSize(window.raw)

proc contentScale*(window: Window): float32 =
  siwin.contentScale(window.raw)

proc size*(window: Window): IVec2 =
  window.raw.size()

proc `size=`*(window: Window, value: IVec2) =
  window.raw.size = value

proc close*(window: Window) =
  window.raw.close()

proc mousePos*(window: Window): IVec2 =
  ivec2(window.raw.mouse.pos.x.int32, window.raw.mouse.pos.y.int32)

proc buttonDown*(window: Window): ButtonView =
  window.down

proc scrollDelta*(window: Window): Vec2 =
  window.lastScroll

proc `icon=`*(window: Window, image: Image) =
  if window.isNil or window.raw.isNil:
    return
  if image.isNil or image.width <= 0 or image.height <= 0 or image.data.len == 0:
    window.raw.icon = nil
    return
  var pixelBuffer = PixelBuffer(
    data: image.data[0].addr,
    size: ivec2(image.width.int32, image.height.int32),
    format: PixelBufferFormat.rgbx_32bit,
  )
  window.raw.icon = pixelBuffer

proc setClipboardString*(value: string) =
  if clipboardWindow.isNil or clipboardWindow.raw.isNil:
    return
  clipboardWindow.raw.clipboard.text = value

proc getClipboardString*(): string =
  if clipboardWindow.isNil or clipboardWindow.raw.isNil:
    return ""
  clipboardWindow.raw.clipboard.text()

proc buttonPressed*(buttons: ButtonView, button: Button): bool =
  button in buttons
