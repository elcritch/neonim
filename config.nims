--nimcache:".nimcache/"

when defined(macosx):
  switch("passC", "-Wno-incompatible-function-pointer-types")

import std/[algorithm, sequtils, strutils, os]

task build, "build neonim":
  exec("nim c " & getEnv("NIMFLAGS") & " -o:bin/neonim src/neonim.nim")

task test, "run unit test":
  for testFile in listFiles("tests/"):
    if testFile.endsWith(".nim") and testFile.startsWith("t"):
      exec("nim c -r " & testFile)
  buildTask()
