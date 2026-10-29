#!/bin/bash
# Copyright (c) 2026 Pingolin LLC
#
# This file is part of Pingolin Note.
#
# Pingolin Note is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Pingolin Note is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Pingolin Note. If not, see <https://www.gnu.org/licenses/>.

# Builds the two iOS UniFFI crates from the mobile-sdk workspace and
# combines them into a single XCFramework at lib/PingolinFFI.xcframework.
#
#   - pingolin_mobile   (crates/mobile-sdk)       — auth + SRP + circle crypto
#   - note_collab_sdk   (crates/note-collab-sdk)  — Yjs + share-wrap signing
#
# SPM via xcodebuild doesn't let two binaryTargets both ship
# Headers/module.modulemap — they collide on the shared
# include/module.modulemap output path. So we libtool the two static
# archives together, merge the headers, and emit a single modulemap
# declaring both `pingolin_mobileFFI` and `collabFFI` modules. One
# xcframework, no collisions.
#
# Requires:
#   - Xcode installed (full Xcode, not just CLT)
#   - rustup with aarch64-apple-ios, aarch64-apple-ios-sim, x86_64-apple-ios targets
#   - protoc on PATH (brew install protobuf)
#   - one of:
#       MOBILE_SDK_REPO   — workspace root (e.g. /path/to/mobile-sdk).
#                           Both crates are resolved relative to this.
#       MOBILE_SDK_SRC    — back-compat. Path to the single mobile-sdk crate
#                           (e.g. /path/to/mobile-sdk/crates/mobile-sdk).
#                           Workspace root is derived from it.

set -euo pipefail

if [[ -z "${MOBILE_SDK_SRC:-}" && -z "${MOBILE_SDK_REPO:-}" ]]; then
  echo "error: set MOBILE_SDK_REPO (workspace root) or MOBILE_SDK_SRC (single-crate path)." >&2
  exit 64
fi

if [[ -n "${MOBILE_SDK_REPO:-}" && -z "${MOBILE_SDK_SRC:-}" ]]; then
  MOBILE_SDK_SRC="$MOBILE_SDK_REPO/crates/mobile-sdk"
fi
if [[ -z "${MOBILE_SDK_REPO:-}" ]]; then
  MOBILE_SDK_REPO="$(cd "$MOBILE_SDK_SRC/../.." && pwd)"
fi
NOTE_COLLAB_SDK_SRC="${NOTE_COLLAB_SDK_SRC:-$MOBILE_SDK_REPO/crates/note-collab-sdk}"

# The SDK's inventory of the third-party crates linked into the framework. It is
# copied next to the bindings at the end, because the app shows it under
# Settings → About → Open Source Licenses: most of those licences require their
# notices to ship with the binary. Resolved before any cd, since MOBILE_SDK_REPO
# may be a relative path.
SDK_LICENSES="$(cd "$MOBILE_SDK_REPO" && pwd)/THIRD_PARTY_LICENSES.md"
if [[ ! -f "$SDK_LICENSES" ]]; then
  echo "error: $SDK_LICENSES not found — MOBILE_SDK_REPO must be a mobile-sdk checkout." >&2
  exit 66
fi

if [[ ! -d "$MOBILE_SDK_SRC" ]]; then
  echo "error: MOBILE_SDK_SRC=$MOBILE_SDK_SRC not found." >&2
  exit 66
fi
if [[ ! -d "$NOTE_COLLAB_SDK_SRC" ]]; then
  echo "error: NOTE_COLLAB_SDK_SRC=$NOTE_COLLAB_SDK_SRC not found." >&2
  exit 66
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STAGING="${STAGING:-$HOME/staging}"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
COMBINED_NAME="PingolinFFI"
SWIFT_MODULE="PingolinNoteSDK"

export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"

echo "=> Building mobile-sdk for iOS (deployment target: $DEPLOYMENT_TARGET)"
echo "   Workspace:           $MOBILE_SDK_REPO"
echo "   pingolin_mobile src: $MOBILE_SDK_SRC"
echo "   note_collab_sdk src: $NOTE_COLLAB_SDK_SRC"
echo "   Staging:             $STAGING"

mkdir -p "$STAGING"

# Builds one crate for all three iOS targets and runs uniffi-bindgen.
# Echoes the per-arch .a paths + bindings dir back to the caller via
# globals (BASH can't easily return structured data).
LAST_TARGET_DIR=""
LAST_BINDINGS_DIR=""

build_crate() {
  local crate_dir="$1"
  local lib_name="$2"
  local bindgen_features="$3"

  echo
  echo "==== Building $lib_name ===="
  cd "$crate_dir"

  for TARGET in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    echo "==> cargo build --release --target $TARGET"
    cargo build --release --target "$TARGET"
  done

  echo "==> Building uniffi-bindgen for $lib_name"
  if [[ -n "$bindgen_features" ]]; then
    cargo build --release --features "$bindgen_features" --bin uniffi-bindgen
  else
    cargo build --release --bin uniffi-bindgen
  fi

  # Workspace members write into the workspace's target dir; standalone
  # crates write under their own. Resolve via cargo metadata.
  local target_dir
  target_dir=$(cargo metadata --no-deps --format-version 1 \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])')

  local crate_staging="$STAGING/$lib_name"
  rm -rf "$crate_staging"
  mkdir -p "$crate_staging/ios-bindings"

  echo "==> Generating Swift bindings via uniffi-bindgen"
  "$target_dir/release/uniffi-bindgen" generate \
    --library "$target_dir/aarch64-apple-ios/release/lib${lib_name}.dylib" \
    --language swift \
    --out-dir "$crate_staging/ios-bindings"

  LAST_TARGET_DIR="$target_dir"
  LAST_BINDINGS_DIR="$crate_staging/ios-bindings"
}

build_crate "$MOBILE_SDK_SRC" "pingolin_mobile" "bindgen"
PINGOLIN_TARGET="$LAST_TARGET_DIR"
PINGOLIN_BINDINGS="$LAST_BINDINGS_DIR"

build_crate "$NOTE_COLLAB_SDK_SRC" "note_collab_sdk" ""
COLLAB_TARGET="$LAST_TARGET_DIR"
COLLAB_BINDINGS="$LAST_BINDINGS_DIR"

#
# Combine into a single xcframework.
#
COMBINED_STAGING="$STAGING/$COMBINED_NAME"
rm -rf "$COMBINED_STAGING"
mkdir -p "$COMBINED_STAGING/headers" "$COMBINED_STAGING/device" "$COMBINED_STAGING/simulator"

echo
echo "==== Combining static archives ===="

echo "==> libtool device slice"
libtool -static -o "$COMBINED_STAGING/device/libPingolinFFI.a" \
  "$PINGOLIN_TARGET/aarch64-apple-ios/release/libpingolin_mobile.a" \
  "$COLLAB_TARGET/aarch64-apple-ios/release/libnote_collab_sdk.a"

echo "==> libtool simulator slices (lipo first per crate, then combine)"
mkdir -p "$COMBINED_STAGING/sim-staging"
lipo -create \
  "$PINGOLIN_TARGET/aarch64-apple-ios-sim/release/libpingolin_mobile.a" \
  "$PINGOLIN_TARGET/x86_64-apple-ios/release/libpingolin_mobile.a" \
  -output "$COMBINED_STAGING/sim-staging/libpingolin_mobile.a"
lipo -create \
  "$COLLAB_TARGET/aarch64-apple-ios-sim/release/libnote_collab_sdk.a" \
  "$COLLAB_TARGET/x86_64-apple-ios/release/libnote_collab_sdk.a" \
  -output "$COMBINED_STAGING/sim-staging/libnote_collab_sdk.a"
libtool -static -o "$COMBINED_STAGING/simulator/libPingolinFFI.a" \
  "$COMBINED_STAGING/sim-staging/libpingolin_mobile.a" \
  "$COMBINED_STAGING/sim-staging/libnote_collab_sdk.a"

echo "==> Merging headers + modulemap"
cp "$PINGOLIN_BINDINGS/pingolin_mobileFFI.h" "$COMBINED_STAGING/headers/"
cp "$COLLAB_BINDINGS/collabFFI.h" "$COMBINED_STAGING/headers/"

cat > "$COMBINED_STAGING/headers/module.modulemap" <<'EOF'
// Merged modulemap for the two UniFFI crates ship together in
// PingolinFFI.xcframework. Each generated Swift binding imports its
// own *FFI module — both modules need to be declared here so SPM
// resolves the imports against the single binary target.

module pingolin_mobileFFI {
    header "pingolin_mobileFFI.h"
    export *
    use "Darwin"
    use "_Builtin_stdbool"
    use "_Builtin_stdint"
}

module collabFFI {
    header "collabFFI.h"
    export *
    use "Darwin"
    use "_Builtin_stdbool"
    use "_Builtin_stdint"
}
EOF

echo "==> Assembling $COMBINED_NAME.xcframework"
rm -rf "$COMBINED_STAGING/$COMBINED_NAME.xcframework"
xcodebuild -create-xcframework \
  -library "$COMBINED_STAGING/device/libPingolinFFI.a" \
  -headers "$COMBINED_STAGING/headers" \
  -library "$COMBINED_STAGING/simulator/libPingolinFFI.a" \
  -headers "$COMBINED_STAGING/headers" \
  -output "$COMBINED_STAGING/$COMBINED_NAME.xcframework"

#
# Install.
#
echo "==> Installing $COMBINED_NAME.xcframework + Swift bindings into note-ios"
cd "$SCRIPT_DIR"
rm -rf lib/PingolinFFI.xcframework \
       lib/PingolinMobile.xcframework \
       lib/NoteCollab.xcframework \
       lib/libpingolin_mobile.a \
       lib/libnote_collab_sdk.a
mkdir -p lib
cp -r "$COMBINED_STAGING/$COMBINED_NAME.xcframework" lib/

# xcodebuild rewrites each xcframework slice's modulemap during
# -create-xcframework, swapping the leading `module <name>FFI` for
# `framework module <slice-name>FFI`. The merged modulemap we authored
# uses the non-framework form because the generated Swift bindings
# `import pingolin_mobileFFI` / `import collabFFI` expect plain
# modules, not framework modules. Overwrite each slice with the
# original merged map.
for slice in "lib/$COMBINED_NAME.xcframework"/*/Headers; do
  cp "$COMBINED_STAGING/headers/module.modulemap" "$slice/module.modulemap"
done

mkdir -p "Sources/$SWIFT_MODULE"
# Wipe stale per-crate files so renames in upstream don't accumulate.
rm -f "Sources/$SWIFT_MODULE"/*.swift "Sources/$SWIFT_MODULE"/*.h "Sources/$SWIFT_MODULE"/module.modulemap
cp "$PINGOLIN_BINDINGS/pingolin_mobile.swift" "Sources/$SWIFT_MODULE/"
cp "$COLLAB_BINDINGS/collab.swift" "Sources/$SWIFT_MODULE/"
cp "$SDK_LICENSES" "Sources/$SWIFT_MODULE/THIRD_PARTY_LICENSES-mobile-sdk.md"

echo
echo "=> Done."
echo "   lib/$COMBINED_NAME.xcframework"
echo "   Sources/$SWIFT_MODULE/pingolin_mobile.swift"
echo "   Sources/$SWIFT_MODULE/collab.swift"
