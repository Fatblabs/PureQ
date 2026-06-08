#!/bin/zsh
set -euo pipefail

APP_INSTALL_PATH="${APP_INSTALL_PATH:-/Applications/PureQ.app}"
UNINSTALL_COMMAND_PATH="${UNINSTALL_COMMAND_PATH:-/Applications/PureQ Uninstall.command}"
SUPPORT_DIR="${SUPPORT_DIR:-/Library/Application Support/PureQ}"
RECOVERY_AGENT_PATH="${RECOVERY_AGENT_PATH:-/Library/LaunchAgents/Sean-s-Apps.PureQ.AudioRecovery.plist}"
DRIVER_INSTALL_PATH="${DRIVER_INSTALL_PATH:-/Library/Audio/Plug-Ins/HAL/PureQ.driver}"
REMOVE_APP="${REMOVE_APP:-1}"
REMOVE_DRIVER="${REMOVE_DRIVER:-1}"
REMOVE_SUPPORT="${REMOVE_SUPPORT:-1}"
PURGE_USER_DATA="${PURGE_USER_DATA:-0}"

if [[ "${1:-}" == "--purge" ]]; then
  PURGE_USER_DATA=1
fi

TEMP_PATHS=()

fail() {
  echo "PureQ uninstall aborted: $*" >&2
  exit 1
}

run_as_root() {
  if [[ "${EUID:-$(/usr/bin/id -u)}" -eq 0 ]]; then
    "$@"
  else
    /usr/bin/sudo "$@"
  fi
}

refresh_root_authorization() {
  if [[ "${EUID:-$(/usr/bin/id -u)}" -ne 0 ]]; then
    /usr/bin/sudo -v
  fi
}

require_exact_path() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  [[ -n "$actual" ]] || fail "$label path is empty"
  [[ "$actual" == "$expected" ]] || fail "$label path must be $expected, got $actual"
}

require_safe_paths() {
  require_exact_path "app install" "$APP_INSTALL_PATH" "/Applications/PureQ.app"
  require_exact_path "uninstaller command" "$UNINSTALL_COMMAND_PATH" "/Applications/PureQ Uninstall.command"
  require_exact_path "support directory" "$SUPPORT_DIR" "/Library/Application Support/PureQ"
  require_exact_path "recovery agent" "$RECOVERY_AGENT_PATH" "/Library/LaunchAgents/Sean-s-Apps.PureQ.AudioRecovery.plist"
  require_exact_path "driver install" "$DRIVER_INSTALL_PATH" "/Library/Audio/Plug-Ins/HAL/PureQ.driver"
}

safe_rm_rf() {
  local path="$1"
  case "$path" in
    /Applications/PureQ.app|/Applications/PureQ\ Uninstall.command|/Library/Audio/Plug-Ins/HAL/PureQ.driver|/Library/Application\ Support/PureQ|/Library/LaunchAgents/Sean-s-Apps.PureQ.AudioRecovery.plist)
      run_as_root /bin/rm -rf "$path"
      ;;
    "$HOME"/Library/Application\ Support/PureQ)
      /bin/rm -rf "$path"
      ;;
    *)
      fail "refusing to remove unexpected path: $path"
      ;;
  esac
}

safe_rm_f() {
  local path="$1"
  case "$path" in
    /Applications/PureQ\ Uninstall.command|/Library/LaunchAgents/Sean-s-Apps.PureQ.AudioRecovery.plist)
      run_as_root /bin/rm -f "$path"
      ;;
    "$HOME"/Library/Preferences/Sean-s-Apps.PureQ.plist)
      /bin/rm -f "$path"
      ;;
    *)
      fail "refusing to remove unexpected file: $path"
      ;;
  esac
}

cleanup() {
  local exit_status=$?
  if [[ "$exit_status" -ne 0 ]]; then
    echo "PureQ uninstall did not complete cleanly. Only PureQ-owned paths were targeted." >&2
  fi
  exit "$exit_status"
}

trap cleanup EXIT
trap 'echo "PureQ uninstall interrupted." >&2; exit 130' INT TERM

quit_running_pureq() {
  /usr/bin/osascript -e 'tell application id "Sean-s-Apps.PureQ" to quit' >/dev/null 2>&1 || true
  /bin/sleep 1
  /usr/bin/pkill -x PureQ >/dev/null 2>&1 || true
}

bootout_recovery_helper() {
  local console_user console_uid
  console_user="$(/usr/bin/stat -f "%Su" /dev/console 2>/dev/null || true)"
  if [[ -n "$console_user" && "$console_user" != "root" ]]; then
    console_uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
    if [[ -n "$console_uid" ]]; then
      run_as_root /bin/launchctl bootout "gui/$console_uid" "$RECOVERY_AGENT_PATH" >/dev/null 2>&1 || true
    fi
  fi
}

require_safe_paths
refresh_root_authorization
bootout_recovery_helper
quit_running_pureq

if [[ "$REMOVE_APP" == "1" ]]; then
  safe_rm_rf "$APP_INSTALL_PATH"
  safe_rm_f "$UNINSTALL_COMMAND_PATH"
fi

if [[ "$REMOVE_DRIVER" == "1" ]]; then
  safe_rm_rf "$DRIVER_INSTALL_PATH"
  run_as_root /usr/bin/killall coreaudiod 2>/dev/null || true
fi

if [[ "$REMOVE_SUPPORT" == "1" ]]; then
  safe_rm_rf "$SUPPORT_DIR"
fi

safe_rm_f "$RECOVERY_AGENT_PATH"

if [[ "$PURGE_USER_DATA" == "1" ]]; then
  [[ -n "$HOME" && "$HOME" != "/" ]] || fail "HOME is not safe for purge"
  safe_rm_rf "$HOME/Library/Application Support/PureQ"
  safe_rm_f "$HOME/Library/Preferences/Sean-s-Apps.PureQ.plist"
fi

echo "PureQ uninstall complete."
