<img width="256" height="256" alt="neonim-icon-capybara2" src="https://github.com/user-attachments/assets/e0246f52-1651-4c27-ba7b-e33c36c423e9" />

# neonim

Neovim GUI frontend written in Nim (Siwin + FigDraw).

<img width="1444" height="944" alt="neonim-screenshot" src="https://github.com/user-attachments/assets/3c12d300-f8eb-4388-bbe8-937c4f90b9ec" />


## Status

It's surprisingly usable.

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

# Run detached (returns terminal immediately; Neonim keeps running if terminal closes)
bin/neonim -D ~/code/my-project
# or
bin/neonim --detach ~/code/my-project

# Set FONT or HDI
HDI=1.8 FONT="JetBrainsMonoNLNerdFont-Thin.ttf" bin/neonim ~/code/my-project

# Increase/decrease mouse wheel scroll speed (default is 1.5)
NEONIM_SCROLL_SPEED_MULTIPLIER=2.0 bin/neonim ~/code/my-project

# Invert mouse wheel direction (accepts: 1/0, true/false, yes/no, on/off)
NEONIM_SCROLL_INVERT=true bin/neonim ~/code/my-project

# Forward nvim args directly
bin/neonim -u NONE --noplugin +':set number' ~/code/my-project

# Connect to an already-running nvim server (TCP)
nvim --headless --listen 127.0.0.1:6666 -u NONE -i NONE --noplugin -n
bin/neonim --server 127.0.0.1:6666

# Connect to an already-running nvim server (Unix socket)
nvim --headless --listen /tmp/neonim.sock -u NONE -i NONE --noplugin -n
bin/neonim --server=unix:///tmp/neonim.sock
```

## Tests

```bash
nim test
```

## Input Notes

- `Cmd +` / `Cmd =` / `Cmd -` (macOS) and `Ctrl +` / `Ctrl =` / `Ctrl -` (Linux/Windows) adjust UI scale.
- `Cmd-c` / `Cmd-v` (macOS) and `Ctrl-c` / `Ctrl-v` (Linux/Windows) copy and paste via the system clipboard.
- `Alt-f` and `Alt-b` are sent as Meta keys (`<A-f>`, `<A-b>`), so terminal word-jump works.
- Double/triple/quadruple left-click send `<2-LeftMouse>`, `<3-LeftMouse>`, `<4-LeftMouse>`.

## Window Icon

The app icon is embedded into the Neonim binary at build time from:

- `data/neonim-icon-128.png`

At runtime Neonim uses the embedded icon first, with file-path fallback from the source tree.
