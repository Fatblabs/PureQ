#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/PureQ.xcodeproj"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="$ROOT_DIR/DerivedData/Install"
DRIVER_PATH="${1:-$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQ.driver}"
INSTALL_PATH="/Library/Audio/Plug-Ins/HAL/PureQ.driver"

if [[ ! -d "$DRIVER_PATH" ]]; then
  xcodebuild \
    -project "$PROJECT" \
    -target PureQDriver \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    build
fi

if [[ ! -d "$DRIVER_PATH" ]]; then
  echo "PureQ.driver was not built at $DRIVER_PATH" >&2
  exit 1
fi

sudo rm -rf "$INSTALL_PATH"
sudo ditto "$DRIVER_PATH" "$INSTALL_PATH"
sudo chown -R root:wheel "$INSTALL_PATH"
sudo chmod -R go-w "$INSTALL_PATH"
sudo killall coreaudiod

echo "Installed PureQ.driver to $INSTALL_PATH"
