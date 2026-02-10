import std/unittest
import neonim

suite "neonim cli args":
  test "parses short detach flag":
    let launch = parseLaunchArgs(@["-D", "./notes"])
    check launch.detach
    check launch.nvimArgs == @["./notes"]

  test "parses long detach flag":
    let launch = parseLaunchArgs(@["--detach", "./notes"])
    check launch.detach
    check launch.nvimArgs == @["./notes"]

  test "keeps detach-like args after --":
    let launch = parseLaunchArgs(@["--", "-D", "--detach"])
    check launch.detach == false
    check launch.nvimArgs == @["--", "-D", "--detach"]

  test "passes folder path through to nvim":
    let cfg = guiConfigFromCli(@["./notes"])
    check cfg.nvimCmd == "nvim"
    check cfg.nvimArgs == @["./notes"]

  test "passes nvim-style args through unchanged":
    let args =
      @["-u", "NONE", "--noplugin", "+set number", "./project", "--", "-literal-path"]
    let cfg = guiConfigFromCli(args)
    check cfg.nvimArgs == args

  test "removes detach flag from forwarded nvim args":
    let cfg = guiConfigFromCli(@["-u", "NONE", "-D", "./project"])
    check cfg.nvimArgs == @["-u", "NONE", "./project"]

  test "keeps nvim -d arg unchanged":
    let cfg = guiConfigFromCli(@["-d", "file1", "file2"])
    check cfg.nvimArgs == @["-d", "file1", "file2"]
