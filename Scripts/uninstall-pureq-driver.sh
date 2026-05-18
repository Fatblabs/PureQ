#!/bin/zsh
set -euo pipefail

INSTALL_PATH="/Library/Audio/Plug-Ins/HAL/PureQ.driver"

if [[ -d "$INSTALL_PATH" ]]; then
  sudo rm -rf "$INSTALL_PATH"
  sudo killall -9 coreaudiod
  echo "Removed PureQ.driver"
else
  echo "PureQ.driver is not installed"
fi
