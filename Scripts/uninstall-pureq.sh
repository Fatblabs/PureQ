#!/bin/zsh
set -euo pipefail

APP_INSTALL_PATH="${APP_INSTALL_PATH:-/Applications/PureQ.app}"
UNINSTALL_COMMAND_PATH="${UNINSTALL_COMMAND_PATH:-/Applications/PureQ Uninstall.command}"
SUPPORT_DIR="${SUPPORT_DIR:-/Library/Application Support/PureQ}"
DRIVER_INSTALL_PATH="${DRIVER_INSTALL_PATH:-/Library/Audio/Plug-Ins/HAL/PureQ.driver}"
REMOVE_APP="${REMOVE_APP:-1}"
REMOVE_DRIVER="${REMOVE_DRIVER:-1}"
REMOVE_SUPPORT="${REMOVE_SUPPORT:-1}"
PURGE_USER_DATA="${PURGE_USER_DATA:-0}"

if [[ "${1:-}" == "--purge" ]]; then
  PURGE_USER_DATA=1
fi

quit_running_pureq() {
  /usr/bin/osascript -e 'tell application id "Sean-s-Apps.PureQ" to quit' >/dev/null 2>&1 || true
  /bin/sleep 1
  /usr/bin/pkill -x PureQ >/dev/null 2>&1 || true
}

sudo -v
quit_running_pureq

if [[ "$REMOVE_APP" == "1" ]]; then
  sudo /bin/rm -rf "$APP_INSTALL_PATH"
  sudo /bin/rm -f "$UNINSTALL_COMMAND_PATH"
fi

if [[ "$REMOVE_DRIVER" == "1" ]]; then
  sudo /bin/rm -rf "$DRIVER_INSTALL_PATH"
  sudo /usr/bin/killall coreaudiod 2>/dev/null || true
fi

if [[ "$REMOVE_SUPPORT" == "1" ]]; then
  sudo /bin/rm -rf "$SUPPORT_DIR"
fi

if [[ "$PURGE_USER_DATA" == "1" ]]; then
  /bin/rm -rf "$HOME/Library/Application Support/PureQ"
  /bin/rm -f "$HOME/Library/Preferences/Sean-s-Apps.PureQ.plist"
fi

echo "PureQ uninstall complete."
