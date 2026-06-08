#!/bin/zsh
set -euo pipefail

export COPYFILE_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/PureQ.xcodeproj"
DERIVED_DATA="$ROOT_DIR/DerivedData/Package"
CONFIGURATION="${CONFIGURATION:-Release}"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_WORK_DIR="$ROOT_DIR/DerivedData/PackageWork"
PACKAGE_ROOT="$PACKAGE_WORK_DIR/root"
PACKAGE_SCRIPTS="$PACKAGE_WORK_DIR/scripts"
COMPONENT_PLIST="$PACKAGE_WORK_DIR/components.plist"
PKG_SIGNING_IDENTITY="${PKG_SIGNING_IDENTITY:-}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
CODE_SIGNING_REQUIRED="${CODE_SIGNING_REQUIRED:-NO}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
APPLICATION_SIGNING_IDENTITY="${APPLICATION_SIGNING_IDENTITY:-$CODE_SIGN_IDENTITY}"

fail() {
  echo "PureQ package aborted: $*" >&2
  exit 1
}

safe_local_rm_rf() {
  local path="$1"
  case "$path" in
    "$ROOT_DIR"/DerivedData/PackageWork/root|"$ROOT_DIR"/DerivedData/PackageWork/scripts|"$ROOT_DIR"/DerivedData/PackageWork/components.plist|"$ROOT_DIR"/dist/PureQ-*.pkg)
      rm -rf "$path"
      ;;
    *)
      fail "refusing to remove unexpected package path: $path"
      ;;
  esac
}

APP_VERSION="$(
  xcodebuild -project "$PROJECT" -target PureQ -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/MARKETING_VERSION/ { print $2; exit }'
)"

if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="1.0"
fi

PKG_PATH="$DIST_DIR/PureQ-$APP_VERSION.pkg"
UNSIGNED_INSTALL_NOTES_PATH="$DIST_DIR/INSTALL-UNSIGNED.txt"

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

APP_SRC="$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQ.app"
DRIVER_SRC="$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQ.driver"
RECOVERY_HELPER_SRC="$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQAudioRecovery"

if [[ ! -d "$APP_SRC" ]]; then
  echo "PureQ.app was not built at $APP_SRC" >&2
  exit 1
fi

if [[ ! -d "$DRIVER_SRC" ]]; then
  echo "PureQ.driver was not built at $DRIVER_SRC" >&2
  exit 1
fi

sign_bundle() {
  local bundle_path="$1"
  local identity="$APPLICATION_SIGNING_IDENTITY"
  local signing_args=(--force --deep)

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

echo "Building audio recovery helper..."
/usr/bin/xcrun swiftc -O "$ROOT_DIR/Scripts/PureQAudioRecovery.swift" -o "$RECOVERY_HELPER_SRC"

echo "Signing package payload..."
sign_bundle "$DRIVER_SRC"
sign_bundle "$APP_SRC"
sign_executable "$RECOVERY_HELPER_SRC"

safe_local_rm_rf "$PACKAGE_ROOT"
safe_local_rm_rf "$PACKAGE_SCRIPTS"
safe_local_rm_rf "$COMPONENT_PLIST"
safe_local_rm_rf "$PKG_PATH"
mkdir -p \
  "$PACKAGE_ROOT/Applications" \
  "$PACKAGE_ROOT/Library/Application Support/PureQ/InstallPayload" \
  "$PACKAGE_ROOT/Library/LaunchAgents" \
  "$PACKAGE_SCRIPTS" \
  "$DIST_DIR"

COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP_SRC" "$PACKAGE_ROOT/Library/Application Support/PureQ/InstallPayload/PureQ.app"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$DRIVER_SRC" "$PACKAGE_ROOT/Library/Application Support/PureQ/InstallPayload/PureQ.driver"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$RECOVERY_HELPER_SRC" "$PACKAGE_ROOT/Library/Application Support/PureQ/PureQAudioRecovery"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$ROOT_DIR/Scripts/uninstall-pureq.sh" "$PACKAGE_ROOT/Library/Application Support/PureQ/uninstall-pureq.sh"
chmod 755 "$PACKAGE_ROOT/Library/Application Support/PureQ/PureQAudioRecovery"
chmod 755 "$PACKAGE_ROOT/Library/Application Support/PureQ/uninstall-pureq.sh"

cat > "$PACKAGE_ROOT/Library/LaunchAgents/Sean-s-Apps.PureQ.AudioRecovery.plist" <<'RECOVERY_LAUNCH_AGENT'
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
  <integer>60</integer>
</dict>
</plist>
RECOVERY_LAUNCH_AGENT

cat > "$PACKAGE_ROOT/Applications/PureQ Uninstall.command" <<'UNINSTALL_WRAPPER'
#!/bin/zsh
exec "/Library/Application Support/PureQ/uninstall-pureq.sh" "$@"
UNINSTALL_WRAPPER
chmod 755 "$PACKAGE_ROOT/Applications/PureQ Uninstall.command"

/usr/bin/xattr -cr "$PACKAGE_ROOT" 2>/dev/null || true
/usr/bin/find "$PACKAGE_ROOT" -name '._*' -delete

cat > "$PACKAGE_SCRIPTS/preinstall" <<'PREINSTALL'
#!/bin/zsh
set -euo pipefail

RECOVERY_AGENT="/Library/LaunchAgents/Sean-s-Apps.PureQ.AudioRecovery.plist"
CONSOLE_USER=$(/usr/bin/stat -f "%Su" /dev/console 2>/dev/null || true)
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]]; then
  CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER" 2>/dev/null || true)
  if [[ -n "$CONSOLE_UID" ]]; then
    /bin/launchctl bootout "gui/$CONSOLE_UID" "$RECOVERY_AGENT" >/dev/null 2>&1 || true
  fi
fi

/usr/bin/osascript -e 'tell application id "Sean-s-Apps.PureQ" to quit' >/dev/null 2>&1 || true
/bin/sleep 1
/usr/bin/pkill -x PureQ >/dev/null 2>&1 || true

exit 0
PREINSTALL

cat > "$PACKAGE_SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/zsh
set -euo pipefail

APP_PATH="/Applications/PureQ.app"
DRIVER_PATH="/Library/Audio/Plug-Ins/HAL/PureQ.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
SUPPORT_DIR="/Library/Application Support/PureQ"
PAYLOAD_DIR="$SUPPORT_DIR/InstallPayload"
APP_PAYLOAD="$PAYLOAD_DIR/PureQ.app"
DRIVER_PAYLOAD="$PAYLOAD_DIR/PureQ.driver"
RECOVERY_HELPER="/Library/Application Support/PureQ/PureQAudioRecovery"
RECOVERY_AGENT="/Library/LaunchAgents/Sean-s-Apps.PureQ.AudioRecovery.plist"
UNINSTALL_SCRIPT="/Library/Application Support/PureQ/uninstall-pureq.sh"
UNINSTALL_COMMAND="/Applications/PureQ Uninstall.command"
TEMP_PATHS=()
ROLLBACK_APP_BACKUP=""
ROLLBACK_APP_PENDING=0
ROLLBACK_DRIVER_BACKUP=""
ROLLBACK_DRIVER_PENDING=0

fail() {
  echo "PureQ postinstall aborted: $*" >&2
  exit 1
}

safe_rm_rf() {
  local path="$1"
  case "$path" in
    /Applications/.PureQ.app.install.*|/Applications/.PureQ.app.previous.*|/Library/Audio/Plug-Ins/HAL/.PureQ.driver.install.*|/Library/Application\ Support/PureQ/InstallPayload)
      /bin/rm -rf "$path"
      ;;
    *)
      fail "refusing to remove unexpected path: $path"
      ;;
  esac
}

cleanup() {
  local exit_status=$?
  if [[ "$exit_status" -ne 0 ]]; then
    echo "PureQ package install did not complete; attempting rollback." >&2
    if [[ "$ROLLBACK_APP_PENDING" == "1" && -n "$ROLLBACK_APP_BACKUP" && ! -e "$APP_PATH" && -e "$ROLLBACK_APP_BACKUP" ]]; then
      /bin/mv "$ROLLBACK_APP_BACKUP" "$APP_PATH" >/dev/null 2>&1 || true
    fi
    if [[ "$ROLLBACK_DRIVER_PENDING" == "1" && -n "$ROLLBACK_DRIVER_BACKUP" && ! -d "$DRIVER_PATH" && -d "$ROLLBACK_DRIVER_BACKUP" ]]; then
      /bin/mv "$ROLLBACK_DRIVER_BACKUP" "$DRIVER_PATH" >/dev/null 2>&1 || true
    fi
  fi
  for path in "${TEMP_PATHS[@]}"; do
    if [[ "$exit_status" -ne 0 && -n "$ROLLBACK_APP_BACKUP" && "$path" == "$ROLLBACK_APP_BACKUP" && ! -e "$APP_PATH" ]]; then
      continue
    fi
    [[ -n "$path" ]] && /bin/rm -rf "$path" >/dev/null 2>&1 || true
  done
  exit "$exit_status"
}

trap cleanup EXIT
trap 'echo "PureQ package install interrupted." >&2; exit 130' INT TERM

install_app_payload() {
  [[ -d "$APP_PAYLOAD" ]] || fail "staged PureQ.app payload is missing"
  local stage="/Applications/.PureQ.app.install.$$"
  local previous="/Applications/.PureQ.app.previous.$$"
  TEMP_PATHS+=("$stage" "$previous")

  safe_rm_rf "$stage"
  /usr/bin/env COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$APP_PAYLOAD" "$stage"
  /usr/bin/xattr -dr com.apple.quarantine "$stage" 2>/dev/null || true

  if [[ -e "$APP_PATH" ]]; then
    safe_rm_rf "$previous"
    ROLLBACK_APP_BACKUP="$previous"
    ROLLBACK_APP_PENDING=1
    /bin/mv "$APP_PATH" "$previous"
  fi
  /bin/mv "$stage" "$APP_PATH"
  ROLLBACK_APP_PENDING=0
}

install_driver_payload() {
  [[ -d "$DRIVER_PAYLOAD" ]] || fail "staged PureQ.driver payload is missing"
  local stage="$HAL_DIR/.PureQ.driver.install.$$"
  local backup="$SUPPORT_DIR/Backups/PureQ.driver.$(/bin/date +%Y%m%d%H%M%S)"
  TEMP_PATHS+=("$stage")

  safe_rm_rf "$stage"
  /bin/mkdir -p "$HAL_DIR" "$SUPPORT_DIR/Backups"
  /usr/bin/env COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$DRIVER_PAYLOAD" "$stage"
  /usr/sbin/chown -R root:wheel "$stage" 2>/dev/null || true
  /bin/chmod -R go-w "$stage" 2>/dev/null || true
  /usr/bin/xattr -cr "$stage" 2>/dev/null || true

  if [[ -e "$DRIVER_PATH" ]]; then
    ROLLBACK_DRIVER_BACKUP="$backup"
    ROLLBACK_DRIVER_PENDING=1
    /bin/mv "$DRIVER_PATH" "$backup"
  fi
  /bin/mv "$stage" "$DRIVER_PATH"
  ROLLBACK_DRIVER_PENDING=0
}

install_app_payload
install_driver_payload

if [[ -f "$UNINSTALL_SCRIPT" ]]; then
  /bin/chmod 755 "$UNINSTALL_SCRIPT" 2>/dev/null || true
fi

if [[ -f "$RECOVERY_HELPER" ]]; then
  /bin/chmod 755 "$RECOVERY_HELPER" 2>/dev/null || true
fi

if [[ -f "$RECOVERY_AGENT" ]]; then
  /bin/chmod 644 "$RECOVERY_AGENT" 2>/dev/null || true
fi

if [[ -f "$UNINSTALL_COMMAND" ]]; then
  /bin/chmod 755 "$UNINSTALL_COMMAND" 2>/dev/null || true
fi

if [[ -d "$DRIVER_PATH" ]]; then
  /usr/sbin/chown -R root:wheel "$DRIVER_PATH" 2>/dev/null || true
  /bin/chmod -R go-w "$DRIVER_PATH" 2>/dev/null || true
  /usr/bin/xattr -cr "$DRIVER_PATH" 2>/dev/null || true
fi

/usr/bin/killall coreaudiod 2>/dev/null || true

CONSOLE_USER=$(/usr/bin/stat -f "%Su" /dev/console 2>/dev/null || true)
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && -f "$RECOVERY_AGENT" ]]; then
  CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER" 2>/dev/null || true)
  if [[ -n "$CONSOLE_UID" ]]; then
    /bin/launchctl bootout "gui/$CONSOLE_UID" "$RECOVERY_AGENT" >/dev/null 2>&1 || true
    /bin/launchctl bootstrap "gui/$CONSOLE_UID" "$RECOVERY_AGENT" >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k "gui/$CONSOLE_UID/Sean-s-Apps.PureQ.AudioRecovery" >/dev/null 2>&1 || true
  fi
fi

safe_rm_rf "$PAYLOAD_DIR"
exit 0
POSTINSTALL

chmod +x "$PACKAGE_SCRIPTS/preinstall" "$PACKAGE_SCRIPTS/postinstall"

COPYFILE_DISABLE=1 pkgbuild --analyze --root "$PACKAGE_ROOT" "$COMPONENT_PLIST"

set_nonrelocatable() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Set $key false" "$COMPONENT_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add $key bool false" "$COMPONENT_PLIST" 2>/dev/null \
    || true
}

component_index=0
while /usr/libexec/PlistBuddy -c "Print :$component_index" "$COMPONENT_PLIST" >/dev/null 2>&1; do
  set_nonrelocatable ":$component_index:BundleIsRelocatable"

  child_index=0
  while /usr/libexec/PlistBuddy -c "Print :$component_index:ChildBundles:$child_index" "$COMPONENT_PLIST" >/dev/null 2>&1; do
    set_nonrelocatable ":$component_index:ChildBundles:$child_index:BundleIsRelocatable"
    child_index=$((child_index + 1))
  done

  component_index=$((component_index + 1))
done

echo "Packaging $PKG_PATH..."
PKGBUILD_ARGS=(
  --root "$PACKAGE_ROOT"
  --scripts "$PACKAGE_SCRIPTS"
  --component-plist "$COMPONENT_PLIST"
  --filter "\\.DS_Store$"
  --filter "/CVS($|/)"
  --filter "/\\.svn($|/)"
  --filter "/\\._[^/]*$"
  --identifier "Sean-s-Apps.PureQ.pkg"
  --version "$APP_VERSION"
  --install-location "/"
  --ownership recommended
)

if [[ -n "$PKG_SIGNING_IDENTITY" ]]; then
  echo "Package signing identity provided; creating a signed package."
  PKGBUILD_ARGS+=(--sign "$PKG_SIGNING_IDENTITY" --timestamp)
else
  echo "No package signing identity provided; creating an unsigned package that does not require an Apple Developer account."
fi

COPYFILE_DISABLE=1 pkgbuild "${PKGBUILD_ARGS[@]}" "$PKG_PATH"

cat > "$UNSIGNED_INSTALL_NOTES_PATH" <<EOF
PureQ unsigned installer
========================

This package does not require an Apple Developer ID or a paid Apple Developer account.
It installs PureQ.app and the bundled CoreAudio HAL driver. macOS should show
"PureQ Virtual Output" after install/repair and while PureQ is running. PureQ
hides that virtual output when the app quits.

Install:
1. Open PureQ-$APP_VERSION.pkg.
2. If macOS blocks it because it is unsigned, right-click the package, choose Open, then confirm.
3. If macOS still blocks it, open System Settings > Privacy & Security and allow the package.

Terminal fallback:
  sudo installer -pkg PureQ-$APP_VERSION.pkg -target /

Uninstall:
  Open /Applications/PureQ Uninstall.command

Force-quit recovery:
  The installer also adds a tiny user-session LaunchAgent. If PureQ is force-quit
  while PureQ Virtual Output is still the macOS default, the helper restores the
  last known hardware output and hides the virtual output within a few seconds.

Unsigned builds are expected to show "no signature" in pkgutil. That is different from a corrupted package.
EOF

echo "Created installer: $PKG_PATH"
echo "Created unsigned-install notes: $UNSIGNED_INSTALL_NOTES_PATH"
