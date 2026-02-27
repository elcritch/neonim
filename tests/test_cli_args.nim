import std/[os, unittest]
import neonim

suite "neonim cli args":
  const defaultScrollSpeedMultiplier = 1.0'f32
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

  test "forwards --server args unchanged":
    let args = @["--server", "127.0.0.1:6666", "+set number"]
    let cfg = guiConfigFromCli(args)
    check cfg.nvimArgs == args

  test "scroll speed multiplier reads env override":
    let envKey = "NEONIM_SCROLL_SPEED_MULTIPLIER"
    let hadEnv = existsEnv(envKey)
    let oldValue = getEnv(envKey)
    defer:
      if hadEnv:
        putEnv(envKey, oldValue)
      else:
        delEnv(envKey)
    putEnv(envKey, "2.25")
    check scrollSpeedMultiplierFromEnv() == 2.25'f32

  test "scroll invert reads env true value":
    let envKey = "NEONIM_SCROLL_INVERT"
    let hadEnv = existsEnv(envKey)
    let oldValue = getEnv(envKey)
    defer:
      if hadEnv:
        putEnv(envKey, oldValue)
      else:
        delEnv(envKey)
    putEnv(envKey, "true")
    check scrollDirectionInvertedFromEnv()

  test "scroll invert reads env false value":
    let envKey = "NEONIM_SCROLL_INVERT"
    let hadEnv = existsEnv(envKey)
    let oldValue = getEnv(envKey)
    defer:
      if hadEnv:
        putEnv(envKey, oldValue)
      else:
        delEnv(envKey)
    putEnv(envKey, "0")
    check not scrollDirectionInvertedFromEnv()
