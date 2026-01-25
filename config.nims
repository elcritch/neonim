--nimcache: ".nimcache/"

task test, "run unit test":
  exec("nim r tests/test_rpc.nim")

