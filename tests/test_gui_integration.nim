import std/[os, unittest]

import neonim
import neonim/types

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
        let testCfg = GuiTestConfig(
          enabled: true, input: ":", expectCmdlinePrefix: ":", timeoutSeconds: 5.0
        )
        let runtime = initGuiRuntime(config, testCfg)
        try:
          while runtime.appRunning:
            discard runtime.stepGui()
        finally:
          runtime.shutdownGui()
        check runtime.testPassed
