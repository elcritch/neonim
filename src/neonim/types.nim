

type GuiConfig* = object
  nvimCmd*: string
  nvimArgs*: seq[string]
  windowTitle*: string

  fontTypeface*: string
  fontSize*: float32

type GuiTestConfig* = object
  enabled*: bool
  input*: string
  expectCmdlinePrefix*: string
  timeoutSeconds*: float
