version       = "0.5.16"
author        = "Jaremy Creechley"
description   = "Neovim backend in Nim and FigDraw"
license       = "MPL2"
srcDir        = "src"
bin           = @["neonim"]

# Dependencies

requires "nim >= 2.2.6"
requires "msgpack4nim"
requires "chronicles"
requires "https://github.com/elcritch/figdraw[siwin] >= 0.19.0"

feature "references":
  requires "https://github.com/neovim/neovim"
  requires "https://github.com/equalsraf/neovim-qt.git"
  requires "https://github.com/elcritch/fastrpc.git"
