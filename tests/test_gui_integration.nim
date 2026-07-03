import std/[os, times, unittest]

import merenda/nimkit as nk
import neonim
import neonim/types

proc pumpUntil(
    runtime: GuiRuntime, predicate: proc(): bool {.closure.}, timeout = 2.0
): bool =
  let startTime = epochTime()
  while runtime.appRunning and epochTime() - startTime <= timeout:
    discard runtime.stepGui()
    if predicate():
      return true
  predicate()

proc pumpFor(runtime: GuiRuntime, duration = 0.25) =
  let startTime = epochTime()
  while runtime.appRunning and epochTime() - startTime <= duration:
    discard runtime.stepGui()

proc pressKey(runtime: GuiRuntime, key: nk.Key) =
  discard runtime.kitWindow.dispatchKeyDown(
    nk.KeyEvent(key: key, keyCode: key.ord, text: "", modifiers: {})
  )

suite "gui integration":
  test "window renders cmdline colon":
    when defined(windows):
      check true
    else:
      if getEnv("NEONIM_GUI_TEST") == "":
        echo "SKIP: set NEONIM_GUI_TEST=1 to run GUI integration test"
        check true
      elif findExe("nvim").len == 0:
        echo "SKIP: `nvim` not found in PATH"
        check true
      else:
        let config = GuiConfig(
          nvimCmd: "nvim",
          nvimArgs: @["-u", "NONE", "-i", "NONE", "--noplugin", "-n"],
          windowTitle: "neonim gui integration",
          fontTypeface: "HackNerdFont-Regular.ttf",
          fontSize: 16.0'f32,
        )
        let runtime = initGuiRuntime(config, showNativeWindow = false)
        try:
          check not runtime.kitWindow.nativeReady()
          discard runtime.kitWindow.makeFirstResponder(runtime.editor)
          discard runtime.kitWindow.dispatchTextInput(":")
          check runtime.pumpUntil(
            proc(): bool =
              runtime.state.cmdlineActive and runtime.state.cmdlineText == ":",
            timeout = 5.0,
          )
          check not runtime.kitWindow.nativeReady()
        finally:
          runtime.shutdownGui()

  test "window keeps editor focus during native tab completion":
    when defined(windows):
      check true
    else:
      if getEnv("NEONIM_GUI_TEST") == "":
        echo "SKIP: set NEONIM_GUI_TEST=1 to run GUI integration test"
        check true
      elif findExe("nvim").len == 0:
        echo "SKIP: `nvim` not found in PATH"
        check true
      else:
        let config = GuiConfig(
          nvimCmd: "nvim",
          nvimArgs: @[],
          windowTitle: "neonim gui tab completion",
          fontTypeface: "HackNerdFont-Regular.ttf",
          fontSize: 16.0'f32,
        )
        let runtime = initGuiRuntime(config, showNativeWindow = false)

        try:
          check not runtime.kitWindow.nativeReady()
          discard runtime.kitWindow.makeFirstResponder(runtime.editor)

          let typed = ":e ~/neonim-missing-tab-complete-dir/"
          for i, ch in typed:
            discard runtime.kitWindow.dispatchTextInput($ch)
            check runtime.pumpUntil(
              proc(): bool =
                runtime.state.cmdlineActive and
                  runtime.state.cmdlineText == typed[0 .. i],
              timeout = 2.0,
            )
            check runtime.kitWindow.firstResponder() == runtime.editor

          runtime.pressKey(nk.keyTab)
          runtime.pumpFor()
          check runtime.kitWindow.firstResponder() == runtime.editor
          check not runtime.kitWindow.nativeReady()

          discard runtime.kitWindow.dispatchTextInput("x")
          runtime.pumpFor()
          check runtime.state.cmdlineText.len > typed.len

          runtime.pressKey(nk.keyEscape)
          check runtime.pumpUntil(
            proc(): bool =
              not runtime.state.cmdlineActive,
            timeout = 2.0,
          )
        finally:
          runtime.shutdownGui()
