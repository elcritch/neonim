--nimcache:".nimcache/"

import std/[algorithm, sequtils, strutils]

task test, "run unit test":
  for testFile in listFiles("tests/"):
    if testFile.endsWith(".nim") and testFile.startsWith("t"):
      exec("nim c -r " & testFile)
