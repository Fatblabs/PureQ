#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/PureQ.xcodeproj"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/DerivedData/Install}"
APP_SRC="${APP_SRC:-$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQ.app}"
DRIVER_SRC="${DRIVER_SRC:-$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQ.driver}"
APP_INSTALL_PATH="${APP_INSTALL_PATH:-/Applications/PureQ.app}"
UNINSTALL_COMMAND_PATH="${UNINSTALL_COMMAND_PATH:-/Applications/PureQ Uninstall.command}"
SUPPORT_DIR="${SUPPORT_DIR:-/Library/Application Support/PureQ}"
DRIVER_INSTALL_PATH="${DRIVER_INSTALL_PATH:-/Library/Audio/Plug-Ins/HAL/PureQ.driver}"
INSTALL_APP="${INSTALL_APP:-1}"
INSTALL_DRIVER="${INSTALL_DRIVER:-1}"
INSTALL_UNINSTALLER="${INSTALL_UNINSTALLER:-1}"
BUILD_IF_MISSING="${BUILD_IF_MISSING:-1}"
FORCE_BUILD="${FORCE_BUILD:-1}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
CODE_SIGNING_REQUIRED="${CODE_SIGNING_REQUIRED:-NO}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
APPLICATION_SIGNING_IDENTITY="${APPLICATION_SIGNING_IDENTITY:-$CODE_SIGN_IDENTITY}"
SIGN_BEFORE_INSTALL="${SIGN_BEFORE_INSTALL:-1}"

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

quit_running_pureq() {
  /usr/bin/osascript -e 'tell application id "Sean-s-Apps.PureQ" to quit' >/dev/null 2>&1 || true
  /bin/sleep 1
  /usr/bin/pkill -x PureQ >/dev/null 2>&1 || true
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

build_if_needed

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
fi

sudo -v
quit_running_pureq

if [[ "$INSTALL_APP" == "1" ]]; then
  echo "Installing PureQ.app to $APP_INSTALL_PATH..."
  sudo /bin/rm -rf "$APP_INSTALL_PATH"
  sudo /usr/bin/env COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$APP_SRC" "$APP_INSTALL_PATH"
  sudo /usr/bin/xattr -dr com.apple.quarantine "$APP_INSTALL_PATH" 2>/dev/null || true
fi

if [[ "$INSTALL_DRIVER" == "1" ]]; then
  echo "Installing PureQ.driver to $DRIVER_INSTALL_PATH..."
  sudo /bin/mkdir -p "$(dirname "$DRIVER_INSTALL_PATH")"
  sudo /bin/rm -rf "$DRIVER_INSTALL_PATH"
  sudo /usr/bin/env COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc --noextattr "$DRIVER_SRC" "$DRIVER_INSTALL_PATH"
  sudo /usr/sbin/chown -R root:wheel "$DRIVER_INSTALL_PATH"
  sudo /bin/chmod -R go-w "$DRIVER_INSTALL_PATH"
  sudo /usr/bin/xattr -cr "$DRIVER_INSTALL_PATH" 2>/dev/null || true
fi

if [[ "$INSTALL_UNINSTALLER" == "1" ]]; then
  install_uninstaller
fi

if [[ "$INSTALL_DRIVER" == "1" ]]; then
  sudo /usr/bin/killall coreaudiod 2>/dev/null || true
fi

echo "PureQ install complete."
