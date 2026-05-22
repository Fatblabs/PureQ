#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="$ROOT_DIR/DerivedData/Install"
DRIVER_PATH="${1:-$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQ.driver}"

INSTALL_APP=0 \
INSTALL_UNINSTALLER=0 \
CONFIGURATION="$CONFIGURATION" \
DERIVED_DATA="$DERIVED_DATA" \
DRIVER_SRC="$DRIVER_PATH" \
"$ROOT_DIR/Scripts/install-pureq.sh"
