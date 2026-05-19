#!/bin/zsh
set -euo pipefail

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

APP_VERSION="$(
  xcodebuild -project "$PROJECT" -target PureQ -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/MARKETING_VERSION/ { print $2; exit }'
)"

if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="1.0"
fi

PKG_PATH="$DIST_DIR/PureQ-$APP_VERSION.pkg"

echo "Building PureQ ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme PureQ \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP_SRC="$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQ.app"
DRIVER_SRC="$DERIVED_DATA/Build/Products/$CONFIGURATION/PureQ.driver"

if [[ ! -d "$APP_SRC" ]]; then
  echo "PureQ.app was not built at $APP_SRC" >&2
  exit 1
fi

if [[ ! -d "$DRIVER_SRC" ]]; then
  echo "PureQ.driver was not built at $DRIVER_SRC" >&2
  exit 1
fi

rm -rf "$PACKAGE_ROOT" "$PACKAGE_SCRIPTS" "$COMPONENT_PLIST" "$PKG_PATH"
mkdir -p \
  "$PACKAGE_ROOT/Applications" \
  "$PACKAGE_ROOT/Library/Audio/Plug-Ins/HAL" \
  "$PACKAGE_SCRIPTS" \
  "$DIST_DIR"

COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP_SRC" "$PACKAGE_ROOT/Applications/PureQ.app"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$DRIVER_SRC" "$PACKAGE_ROOT/Library/Audio/Plug-Ins/HAL/PureQ.driver"
/usr/bin/xattr -cr "$PACKAGE_ROOT" 2>/dev/null || true
/usr/bin/find "$PACKAGE_ROOT" -name '._*' -delete

cat > "$PACKAGE_SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/zsh
set -e

DRIVER_PATH="/Library/Audio/Plug-Ins/HAL/PureQ.driver"

if [[ -d "$DRIVER_PATH" ]]; then
  /usr/sbin/chown -R root:wheel "$DRIVER_PATH" 2>/dev/null || true
  /bin/chmod -R go-w "$DRIVER_PATH" 2>/dev/null || true
fi

/usr/bin/killall coreaudiod 2>/dev/null || true

exit 0
POSTINSTALL

chmod +x "$PACKAGE_SCRIPTS/postinstall"

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
  --identifier "Sean-s-Apps.PureQ.pkg"
  --version "$APP_VERSION"
  --install-location "/"
  --ownership recommended
)

if [[ -n "$PKG_SIGNING_IDENTITY" ]]; then
  PKGBUILD_ARGS+=(--sign "$PKG_SIGNING_IDENTITY" --timestamp)
fi

COPYFILE_DISABLE=1 pkgbuild "${PKGBUILD_ARGS[@]}" "$PKG_PATH"

echo "Created installer: $PKG_PATH"
