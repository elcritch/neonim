import std/unittest
import neonim

suite "neonim cli args":
  test "passes folder path through to nvim":
    let cfg = guiConfigFromCli(@["./notes"])
    check cfg.nvimCmd == "nvim"
    check cfg.nvimArgs == @["./notes"]

  test "passes nvim-style args through unchanged":
    let args =
      @["-u", "NONE", "--noplugin", "+set number", "./project", "--", "-literal-path"]
    let cfg = guiConfigFromCli(args)
    check cfg.nvimArgs == args
