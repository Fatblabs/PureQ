#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/PureQ.xcodeproj"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/DerivedData/Install}"
APP_SRC="${APP_SRC:-$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQ.app}"
DRIVER_SRC="${DRIVER_SRC:-$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQ.driver}"
RECOVERY_HELPER_SRC="${RECOVERY_HELPER_SRC:-$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQAudioRecovery}"
APP_INSTALL_PATH="${APP_INSTALL_PATH:-/Applications/PureQ.app}"
UNINSTALL_COMMAND_PATH="${UNINSTALL_COMMAND_PATH:-/Applications/PureQ Uninstall.command}"
SUPPORT_DIR="${SUPPORT_DIR:-/Library/Application Support/PureQ}"
RECOVERY_AGENT_PATH="${RECOVERY_AGENT_PATH:-/Library/LaunchAgents/Sean-s-Apps.PureQ.AudioRecovery.plist}"
DRIVER_INSTALL_PATH="${DRIVER_INSTALL_PATH:-/Library/Audio/Plug-Ins/HAL/PureQ.driver}"
INSTALL_APP="${INSTALL_APP:-1}"
INSTALL_DRIVER="${INSTALL_DRIVER:-1}"
INSTALL_UNINSTALLER="${INSTALL_UNINSTALLER:-1}"
INSTALL_RECOVERY_HELPER="${INSTALL_RECOVERY_HELPER:-1}"
BUILD_IF_MISSING="${BUILD_IF_MISSING:-1}"
FORCE_BUILD="${FORCE_BUILD:-1}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
CODE_SIGNING_REQUIRED="${CODE_SIGNING_REQUIRED:-NO}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
APPLICATION_SIGNING_IDENTITY="${APPLICATION_SIGNING_IDENTITY:-$CODE_SIGN_IDENTITY}"
SIGN_BEFORE_INSTALL="${SIGN_BEFORE_INSTALL:-1}"

TEMP_PATHS=()
ROLLBACK_APP_BACKUP=""
ROLLBACK_APP_PENDING=0
ROLLBACK_DRIVER_BACKUP=""
ROLLBACK_DRIVER_PENDING=0

fail() {
  echo "PureQ install aborted: $*" >&2
  exit 1
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

require_named_source() {
  local label="$1"
  local actual="$2"
  local expected_name="$3"
  [[ -n "$actual" ]] || fail "$label source path is empty"
  [[ "$actual" == */"$expected_name" ]] || fail "$label source must end with $expected_name, got $actual"
  [[ "$actual" != "/" ]] || fail "$label source cannot be the filesystem root"
}

require_safe_payload_sources() {
  if [[ "$INSTALL_APP" == "1" ]]; then
    require_named_source "app" "$APP_SRC" "PureQ.app"
  fi
  if [[ "$INSTALL_DRIVER" == "1" ]]; then
    require_named_source "driver" "$DRIVER_SRC" "PureQ.driver"
  fi
  if [[ "$INSTALL_RECOVERY_HELPER" == "1" ]]; then
    require_named_source "recovery helper" "$RECOVERY_HELPER_SRC" "PureQAudioRecovery"
  fi
}

safe_rm_rf() {
  local path="$1"
  case "$path" in
    /Applications/PureQ.app|/Applications/PureQ\ Uninstall.command|/Applications/.PureQ.app.install.*|/Applications/.PureQ.app.previous.*|/Library/Audio/Plug-Ins/HAL/PureQ.driver|/Library/Audio/Plug-Ins/HAL/.PureQ.driver.install.*|/Library/Application\ Support/PureQ|/Library/LaunchAgents/Sean-s-Apps.PureQ.AudioRecovery.plist|/Library/Application\ Support/PureQ/Backups/PureQ.driver.*)
      sudo /bin/rm -rf "$path"
      ;;
    *)
      fail "refusing to remove unexpected path: $path"
      ;;
  esac
}

cleanup() {
  local exit_status=$?
  if [[ "$exit_status" -ne 0 ]]; then
    echo "PureQ install did not complete; cleaning up temporary files." >&2
    if [[ "$ROLLBACK_APP_PENDING" == "1" && -n "$ROLLBACK_APP_BACKUP" && ! -e "$APP_INSTALL_PATH" && -e "$ROLLBACK_APP_BACKUP" ]]; then
      sudo -n /bin/mv "$ROLLBACK_APP_BACKUP" "$APP_INSTALL_PATH" >/dev/null 2>&1 || true
    fi
    if [[ "$ROLLBACK_DRIVER_PENDING" == "1" && -n "$ROLLBACK_DRIVER_BACKUP" && ! -d "$DRIVER_INSTALL_PATH" && -d "$ROLLBACK_DRIVER_BACKUP" ]]; then
      sudo -n /bin/mv "$ROLLBACK_DRIVER_BACKUP" "$DRIVER_INSTALL_PATH" >/dev/null 2>&1 || true
    fi
  fi
  for path in "${TEMP_PATHS[@]}"; do
    if [[ "$exit_status" -ne 0 && -n "$ROLLBACK_APP_BACKUP" && "$path" == "$ROLLBACK_APP_BACKUP" && ! -e "$APP_INSTALL_PATH" ]]; then
      continue
    fi
    [[ -n "$path" ]] && sudo -n /bin/rm -rf "$path" >/dev/null 2>&1 || true
  done
  exit "$exit_status"
}

trap cleanup EXIT
trap 'echo "PureQ install interrupted." >&2; exit 130' INT TERM

build_if_needed() {
  if [[ "$BUILD_IF_MISSING" == "0" ]]; then
    return
  fi

  if [[ "$FORCE_BUILD" == "1" ]] || [[ "$INSTALL_APP" == "1" && ! -d "$APP_SRC" ]] || [[ "$INSTALL_DRIVER" == "1" && ! -d "$DRIVER_SRC" ]]; then
    echo "Building PureQ ($CONFIGURATION)..."
    xcodebuild \
      -project "$PROJECT" \
      -scheme PureQ \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$DERIVED_DATA" \
      CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
      CODE_SIGNING_REQUIRED="$CODE_SIGNING_REQUIRED" \
      CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
      clean \
      build
  fi
}

build_recovery_helper() {
  if [[ "$INSTALL_RECOVERY_HELPER" != "1" ]]; then
    return
  fi

  echo "Building PureQ audio recovery helper..."
  /usr/bin/xcrun swiftc -O "$ROOT_DIR/Scripts/PureQAudioRecovery.swift" -o "$RECOVERY_HELPER_SRC"
}

sign_bundle() {
  local bundle_path="$1"
  local identity="$APPLICATION_SIGNING_IDENTITY"
  local signing_args=(--force --deep)

  [[ -d "$bundle_path" ]] || return

  if [[ -z "$identity" ]]; then
    identity="-"
  fi

  signing_args+=(--sign "$identity")
  if [[ "$identity" == "-" ]]; then
    signing_args+=(--timestamp=none)
  else
    signing_args+=(--options runtime --timestamp)
  fi

  /usr/bin/codesign "${signing_args[@]}" "$bundle_path"
}

sign_executable() {
  local executable_path="$1"
  local identity="$APPLICATION_SIGNING_IDENTITY"
  local signing_args=(--force)

  [[ -f "$executable_path" ]] || return

  if [[ -z "$identity" ]]; then
    identity="-"
  fi

  signing_args+=(--sign "$identity")
  if [[ "$identity" == "-" ]]; then
    signing_args+=(--timestamp=none)
  else
    signing_args+=(--options runtime --timestamp)
  fi

  /usr/bin/codesign "${signing_args[@]}" "$executable_path"
}

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
      sudo /bin/launchctl bootout "gui/$console_uid" "$RECOVERY_AGENT_PATH" >/dev/null 2>&1 || true
    fi
  fi
}

install_uninstaller() {
  sudo /bin/mkdir -p "$SUPPORT_DIR"
  sudo /usr/bin/env COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$ROOT_DIR/Scripts/uninstall-pureq.sh" "$SUPPORT_DIR/uninstall-pureq.sh"
  sudo /bin/chmod 755 "$SUPPORT_DIR/uninstall-pureq.sh"

  local wrapper
  wrapper="$(/usr/bin/mktemp)"
  /bin/cat > "$wrapper" <<'WRAPPER'
#!/bin/zsh
exec "/Library/Application Support/PureQ/uninstall-pureq.sh" "$@"
WRAPPER
  sudo /usr/bin/install -m 755 "$wrapper" "$UNINSTALL_COMMAND_PATH"
  /bin/rm -f "$wrapper"
}

install_recovery_helper() {
  [[ "$INSTALL_RECOVERY_HELPER" == "1" ]] || return

  sudo /bin/mkdir -p "$SUPPORT_DIR" "$(dirname "$RECOVERY_AGENT_PATH")"
  sudo /usr/bin/env COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$RECOVERY_HELPER_SRC" "$SUPPORT_DIR/PureQAudioRecovery"
  sudo /bin/chmod 755 "$SUPPORT_DIR/PureQAudioRecovery"

  local agent
  agent="$(/usr/bin/mktemp)"
  /bin/cat > "$agent" <<'AGENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>Sean-s-Apps.PureQ.AudioRecovery</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Library/Application Support/PureQ/PureQAudioRecovery</string>
    <string>--restore-if-needed</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>10</integer>
</dict>
</plist>
AGENT
  sudo /usr/bin/install -m 644 "$agent" "$RECOVERY_AGENT_PATH"
  /bin/rm -f "$agent"

  local console_user console_uid
  console_user="$(/usr/bin/stat -f "%Su" /dev/console 2>/dev/null || true)"
  if [[ -n "$console_user" && "$console_user" != "root" ]]; then
    console_uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
    if [[ -n "$console_uid" ]]; then
      sudo /bin/launchctl bootout "gui/$console_uid" "$RECOVERY_AGENT_PATH" >/dev/null 2>&1 || true
      sudo /bin/launchctl bootstrap "gui/$console_uid" "$RECOVERY_AGENT_PATH" >/dev/null 2>&1 || true
      sudo /bin/launchctl kickstart -k "gui/$console_uid/Sean-s-Apps.PureQ.AudioRecovery" >/dev/null 2>&1 || true
    fi
  fi
}

install_app_payload() {
  local stage="/Applications/.PureQ.app.install.$$"
  local previous="/Applications/.PureQ.app.previous.$$"
  TEMP_PATHS+=("$stage" "$previous")

  safe_rm_rf "$stage"
  sudo /usr/bin/env COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$APP_SRC" "$stage"
  sudo /usr/bin/xattr -dr com.apple.quarantine "$stage" 2>/dev/null || true

  if [[ -e "$APP_INSTALL_PATH" ]]; then
    safe_rm_rf "$previous"
    ROLLBACK_APP_BACKUP="$previous"
    ROLLBACK_APP_PENDING=1
    sudo /bin/mv "$APP_INSTALL_PATH" "$previous"
  fi
  sudo /bin/mv "$stage" "$APP_INSTALL_PATH"
  ROLLBACK_APP_PENDING=0
}

install_driver_payload() {
  local stage="/Library/Audio/Plug-Ins/HAL/.PureQ.driver.install.$$"
  local backup="$SUPPORT_DIR/Backups/PureQ.driver.$(/bin/date +%Y%m%d%H%M%S)"
  TEMP_PATHS+=("$stage")

  safe_rm_rf "$stage"
  sudo /bin/mkdir -p "$(dirname "$DRIVER_INSTALL_PATH")" "$SUPPORT_DIR/Backups"
  sudo /usr/bin/env COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$DRIVER_SRC" "$stage"
  sudo /usr/sbin/chown -R root:wheel "$stage"
  sudo /bin/chmod -R go-w "$stage"
  sudo /usr/bin/xattr -cr "$stage" 2>/dev/null || true

  if [[ -e "$DRIVER_INSTALL_PATH" ]]; then
    ROLLBACK_DRIVER_BACKUP="$backup"
    ROLLBACK_DRIVER_PENDING=1
    sudo /bin/mv "$DRIVER_INSTALL_PATH" "$backup"
  fi

  sudo /bin/mv "$stage" "$DRIVER_INSTALL_PATH"
  ROLLBACK_DRIVER_PENDING=0
}

require_safe_paths
require_safe_payload_sources
build_if_needed
build_recovery_helper

if [[ "$INSTALL_APP" == "1" && ! -d "$APP_SRC" ]]; then
  echo "PureQ.app was not built at $APP_SRC" >&2
  exit 1
fi

if [[ "$INSTALL_DRIVER" == "1" && ! -d "$DRIVER_SRC" ]]; then
  echo "PureQ.driver was not built at $DRIVER_SRC" >&2
  exit 1
fi

if [[ "$SIGN_BEFORE_INSTALL" == "1" ]]; then
  echo "Signing install payload..."
  sign_bundle "$DRIVER_SRC"
  sign_bundle "$APP_SRC"
  sign_executable "$RECOVERY_HELPER_SRC"
fi

sudo -v
bootout_recovery_helper
quit_running_pureq

if [[ "$INSTALL_APP" == "1" ]]; then
  echo "Installing PureQ.app to $APP_INSTALL_PATH..."
  install_app_payload
fi

if [[ "$INSTALL_DRIVER" == "1" ]]; then
  echo "Installing PureQ.driver to $DRIVER_INSTALL_PATH..."
  install_driver_payload
fi

if [[ "$INSTALL_UNINSTALLER" == "1" ]]; then
  install_uninstaller
fi

install_recovery_helper

if [[ "$INSTALL_DRIVER" == "1" ]]; then
  sudo /usr/bin/killall coreaudiod 2>/dev/null || true
fi

echo "PureQ install complete."
