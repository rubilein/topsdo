#!/bin/sh
# Short launcher for Linux/macOS: symlink it into your PATH, e.g.
#   ln -s /path/to/topsdo/t ~/.local/bin/t
exec pwsh -NoProfile -NoLogo -File "$(dirname "$(readlink -f "$0")")/topsdo.ps1" "$@"
