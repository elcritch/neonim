<img width="512" height="512" alt="neonim-icon-capybara2" src="https://github.com/user-attachments/assets/e0246f52-1651-4c27-ba7b-e33c36c423e9" />

# neonim

Neovim GUI frontend written in Nim (Windy + FigDraw).


## Status

This project is actively evolving. Core UI rendering, input forwarding, and embedded nvim RPC are working.

## Requirements

- Nim `>= 2.2.6`
- `nvim` in `PATH`
- Atlas workspace/dependencies (`atlas install`)

## Build

```bash
atlas install
nim build
```

Binary output:

- `bin/neonim`

## Run

```bash
# Open current directory
bin/neonim .

# Open a specific folder
bin/neonim ~/code/my-project

# Forward nvim args directly
bin/neonim -u NONE --noplugin +':set number' ~/code/my-project
```

## Tests

```bash
nim test
```

## Input Notes

- `Cmd +` / `Cmd -` adjusts UI scale.
- `Alt-f` and `Alt-b` are sent as Meta keys (`<A-f>`, `<A-b>`), so terminal word-jump works.
- Double/triple/quadruple left-click send `<2-LeftMouse>`, `<3-LeftMouse>`, `<4-LeftMouse>`.

## Window Icon

The app icon is embedded into the Neonim binary at build time from:

- `data/neonim-icon-128.png`

At runtime Neonim uses the embedded icon first, with file-path fallback from the source tree.
