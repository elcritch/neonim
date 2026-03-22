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

  test "font typeface reads NEONIM_FONT env override":
    let envKey = "NEONIM_FONT"
    let hadEnv = existsEnv(envKey)
    let oldValue = getEnv(envKey)
    defer:
      if hadEnv:
        putEnv(envKey, oldValue)
      else:
        delEnv(envKey)
    putEnv(envKey, "JetBrainsMonoNLNerdFont-Regular.ttf")
    let cfg = guiConfigFromCli(@["./notes"])
    check cfg.fontTypeface == "JetBrainsMonoNLNerdFont-Regular.ttf"

  test "font size reads NEONIM_FONTSIZE env override":
    let envKey = "NEONIM_FONTSIZE"
    let hadEnv = existsEnv(envKey)
    let oldValue = getEnv(envKey)
    defer:
      if hadEnv:
        putEnv(envKey, oldValue)
      else:
        delEnv(envKey)
    putEnv(envKey, "19")
    check fontSizeFromEnv() == 19.0'f32
    let cfg = guiConfigFromCli(@["./notes"])
    check cfg.fontSize == 19.0'f32

  test "font size falls back when NEONIM_FONTSIZE is invalid":
    let envKey = "NEONIM_FONTSIZE"
    let hadEnv = existsEnv(envKey)
    let oldValue = getEnv(envKey)
    defer:
      if hadEnv:
        putEnv(envKey, oldValue)
      else:
        delEnv(envKey)
    putEnv(envKey, "not-a-number")
    check fontSizeFromEnv() == 16.0'f32

  test "ui scale reads NEONIM_HDI env override":
    let envKey = "NEONIM_HDI"
    let hadEnv = existsEnv(envKey)
    let oldValue = getEnv(envKey)
    defer:
      if hadEnv:
        putEnv(envKey, oldValue)
      else:
        delEnv(envKey)
    putEnv(envKey, "1.8")
    check uiScaleFromEnv(1.0'f32) == 1.8'f32

  test "ui scale falls back when NEONIM_HDI is invalid":
    let envKey = "NEONIM_HDI"
    let hadEnv = existsEnv(envKey)
    let oldValue = getEnv(envKey)
    defer:
      if hadEnv:
        putEnv(envKey, oldValue)
      else:
        delEnv(envKey)
    putEnv(envKey, "bogus")
    check uiScaleFromEnv(1.5'f32) == 1.5'f32

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
