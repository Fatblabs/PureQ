#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

REMOVE_APP=0 REMOVE_SUPPORT=0 "$ROOT_DIR/Scripts/uninstall-pureq.sh"
