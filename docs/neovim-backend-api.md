# Neovim backend API (as used by deps/neovim-qt)

This document summarizes how `deps/neovim-qt` interfaces with Neovim over
msgpack-rpc and how to implement a compatible backend.

## Overview

Neovim runs as a separate process and exposes a msgpack-rpc API. `neovim-qt`
wraps this API with:

- A transport abstraction (`MsgpackIODevice`) that reads/writes msgpack frames
  over a `QIODevice`, stdin/stdout, or a socket.
- A connection manager (`NeovimConnector`) that performs the initial handshake
  and exposes versioned API objects (`NeovimApi0..6`).
- Auto-generated API bindings built from `nvim --api-info` that convert
  function calls to msgpack requests and responses.
- GUI-specific attachment and notification handling (`Shell`, `nvim_gui_shim`).

The implementation follows the Neovim msgpack-rpc protocol:
https://neovim.io/doc/user/api.html

## Transport and connection types

`NeovimConnector` can connect using several mechanisms:

- Spawned process (`spawn()`): starts `nvim` and communicates via stdio.
- Socket (`connectToSocket()`): connects to a local socket/pipe.
- TCP (`connectToHost()`): connects to a host/port.
- Stdio (`fromStdinOut()`): for embedding as a child process.

`MsgpackIODevice` is the core transport wrapper. It:

- Uses `msgpack_packer` to write msgpack to the underlying device.
- Uses `msgpack_unpacker` to incrementally parse incoming data.
- Dispatches parsed messages as requests, responses, or notifications.

## Startup handshake and API discovery

`NeovimConnector` considers the connection ready only after it retrieves
metadata via:

- RPC call: `vim_get_api_info` (sent by `discoverMetadata()`)
- Expected response: a two-element list `[channel_id, metadata]`

`metadata` includes:

- `version.api_compatible` and `version.api_level`
- `ui_options` (supported UI capabilities)

The connector records these values and emits `ready()` once they are valid.
API wrappers are only created after readiness is confirmed.

## Message framing (msgpack-rpc)

`MsgpackIODevice` enforces the Neovim msgpack-rpc framing rules:

- Request: `[0, msgid, method, args]`
- Response: `[1, msgid, error, result]`
- Notification: `[2, method, params]`

Notes from the implementation:

- `method` is serialized as a UTF-8 string (msgpack bin or str).
- `args`/`params` must be msgpack arrays.
- `msgid` is a monotonically increasing integer managed by the client.
- Invalid frames are rejected with debug logs or error responses.

## Request lifecycle

1. `startRequestUnchecked(method, argcount)` packs the request header and
   creates a `MsgpackRequest` object with an ID and timeout.
2. The caller serializes each argument with `MsgpackIODevice::send()`.
3. Responses are dispatched by `dispatchResponse()`:
   - On error, `MsgpackRequest::error` is emitted.
   - On success, `MsgpackRequest::finished` is emitted.
4. Requests are removed from the pending map on completion or timeout.

## Notifications and server->client requests

- Notifications (`type=2`) are decoded into a method name and parameter list
  and emitted as `notification(method, params)`.
- Incoming RPC requests (`type=0`) can be handled by assigning a
  `MsgpackRequestHandler` to the transport. This allows Neovim to call into the
  client (used for GUI shim events or custom handlers).

## API bindings and type handling

Bindings are generated from `nvim --api-info` via
`deps/neovim-qt/bindings/generate_bindings.py` and compiled into
`src/auto/neovimapi{N}.h/.cpp`.

Key mappings used by the generator:

- Neovim types to C++/Qt types:
  - `Integer` -> `int64_t`
  - `Float` -> `double`
  - `Boolean` -> `bool`
  - `String` -> `QByteArray` (UTF-8)
  - `Object` -> `QVariant`
  - `Array` -> `QVariantList`
  - `Dictionary` -> `QVariantMap`
  - `Window`/`Buffer`/`Tabpage` -> `int64_t` (ext types)
  - `ArrayOf(Integer, 2)` -> `QPoint` (row/col pair)

`MsgpackIODevice` encodes/decodes these types and validates `QVariant`
serializability before sending.

## UI attachment and GUI-specific events

The GUI uses the Neovim UI API after the initial handshake:

- `nvim_ui_attach(width, height, options)` (API level >= 2)
- Legacy fallback: `ui_attach(width, height, rgb)` (API level 0)

In `Shell::init()` the GUI builds an options map, including `ext_*` toggles
(e.g. `ext_linegrid`, `ext_popupmenu`, `ext_tabline`) and `rgb=true`.

The GUI also subscribes to additional UI events:

- `vim_subscribe("Gui")` to receive shim events.
- `runtime plugin/nvim_gui_shim.vim` loads a helper plugin that forwards
  GUI-related commands via `rpcnotify()` (see
  `deps/neovim-qt/src/gui/runtime/doc/nvim_gui_shim.txt`).

Notifications are routed through `NeovimApi0::neovimNotification` and
`Shell::handleNeovimNotification()`.

## Implementing a compatible backend

The essential steps to implement a backend similar to `neovim-qt` are:

1. Open a transport
   - Spawn `nvim` and connect to its stdio, or connect to a socket/TCP host.
   - Ensure the transport is sequential and supports incremental reads.

2. Implement msgpack-rpc framing
   - Serialize requests as `[0, msgid, method, args]`.
   - Parse incoming frames and dispatch based on the `type` element.
   - Maintain a pending request map keyed by `msgid`.

3. Perform metadata discovery
   - Call `vim_get_api_info` and parse `[channel_id, metadata]`.
   - Read `version.api_compatible` and `version.api_level`.
   - Only enable APIs supported by `api_level` and `api_compatible`.

4. Generate or bind API functions
   - Use `nvim --api-info` to build a function table and type map.
   - Provide helpers that send requests and return a handle for responses.

5. Handle UI attach (for GUIs)
   - Call `nvim_ui_attach` with `ext_*` options and `rgb=true`.
   - Subscribe to `Gui` events and load a GUI shim plugin if needed.
   - Route redraw and GUI notifications to your renderer and UI handlers.

6. Implement error and timeout handling
   - Time out pending requests and surface errors from responses.
   - Treat transport errors as fatal and close/cleanup the connection.

## RPC calls needed for a GUI backend

This is the minimum call set that `neovim-qt` relies on to act as a GUI client.
Some calls have legacy alternatives depending on API level.

- `vim_get_api_info`
  - Handshake; returns `[channel_id, metadata]` with `api_level`, `api_compatible`,
    and `ui_options`.
- `nvim_ui_attach(width, height, options)` (API >= 2)
  - Attach as a UI and enable `ext_*` features and `rgb`.
- `ui_attach(width, height, rgb)` (legacy API 0)
  - Fallback attach for older API levels.
- `nvim_ui_try_resize(width, height)` / `ui_try_resize(width, height)`
  - Used when the GUI window resizes and Neovim needs new grid dimensions.
- `vim_subscribe("Gui")`
  - Subscribe to GUI-specific notifications (see the shim plugin).
- `vim_command("runtime plugin/nvim_gui_shim.vim")`
  - Load the GUI shim that bridges GUI commands and events over rpcnotify.
- `vim_command(<ginit.vim command>)`
  - Optional: run GUI init commands (e.g., `GuiFont`).
- `vim_set_var("GuiWindowFrameless", 0|1)`
  - Publish initial GUI state to Neovim.

Input and interaction calls used by the GUI layer:

- `nvim_input(keys)` or `nvim_feedkeys(keys, mode, escape_ks)`
  - Send keyboard input into Neovim.
- `nvim_input_mouse(button, action, modifier, grid, row, col)`
  - Mouse input (used when supported by the API level).
- `nvim_ui_set_option(name, value)`
  - Update UI options at runtime if needed (e.g., `rgb`, `ext_*`).

Notifications you must handle:

- `redraw` notifications (UI protocol)
  - Drive rendering updates for grid, cursor, highlights, etc.
- `Gui` notifications (from shim)
  - Window events like maximize, fullscreen, opacity, clipboard hooks, etc.

The exact redraw event set depends on `ui_options` and `ext_linegrid`. The GUI
backend should implement the current Neovim UI protocol and map those events
into the renderer and widgets.

## Minimal wire examples

Request `vim_get_api_info`:

```text
[0, 1, "vim_get_api_info", []]
```

Response (success):

```text
[1, 1, nil, [channel_id, {"version": {"api_compatible": 0, "api_level": 6}, ...}]]
```

Notification (redraw event):

```text
[2, "redraw", [["resize", [rows, cols]], ...]]
```

These examples match how `MsgpackIODevice` frames and dispatches messages.
