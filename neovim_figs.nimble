version       = "0.1.0"
author        = "Jaremy Creechley"
description   = "Neovim backend in Nim and FigDraw"
license       = "MPL2"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.6"
requires "msgpack4nim"

requires "https://github.com/elcritch/figdraw"

feature "references":
  requires "https://github.com/equalsraf/neovim-qt.git"

