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
        check rpcUnpack[int](inputResp.result) > 0

        let lineResp =
          client.callAndWait("nvim_get_current_line", rpcPackParams(), timeout = 10.0)
        check lineResp.error.isNilValue
        check rpcUnpack[string](lineResp.result) == "hello"

  test "colon command via input":
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

        let setVarResp = client.callAndWait(
          "nvim_input", rpcPackParams(":let g:neonim_test_var='ok'\n"), timeout = 10.0
        )
        check setVarResp.error.isNilValue

        let getVarResp = client.callAndWait(
          "nvim_get_var", rpcPackParams("neonim_test_var"), timeout = 10.0
        )
        check getVarResp.error.isNilValue
        check rpcUnpack[string](getVarResp.result) == "ok"

  test "nvim_command executes ex":
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

        let cmdResp = client.callAndWait(
          "nvim_command",
          rpcPackParams("call setline(1, 'via-command')"),
          timeout = 10.0,
        )
        check cmdResp.error.isNilValue

        let lineResp =
          client.callAndWait("nvim_get_current_line", rpcPackParams(), timeout = 10.0)
        check lineResp.error.isNilValue
        check rpcUnpack[string](lineResp.result) == "via-command"

  test ":q exits":
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

        client.notify("nvim_input", rpcPackParams(":q\n"))
        check client.waitForExit(timeout = 5.0)
