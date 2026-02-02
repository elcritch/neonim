import std/[os, unittest]
import neonim/nvim_client
import neonim/rpc
import msgpack4nim

suite "neovim client":
  test "basic text input":
    when defined(windows):
      check true
    else:
      if findExe("nvim").len == 0:
        echo "SKIP: `nvim` not found in PATH"
        check true
      else:
        let client = newNeovimClient()
        defer:
          client.stop()

        client.start(
          nvimCmd = "nvim",
          args = @["--headless", "-u", "NONE", "-i", "NONE", "--noplugin", "-n"],
        )

        discard client.discoverMetadata()

        let inputResp =
          client.callAndWait("nvim_input", rpcPackParams("ihello\x1b"), timeout = 10.0)
        check inputResp.error.isNilValue

        let lineResp =
          client.callAndWait("nvim_get_current_line", rpcPackParams(), timeout = 10.0)
        check lineResp.error.isNilValue
        check rpcUnpack[string](lineResp.result) == "hello"
