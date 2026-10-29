#!/usr/bin/env bash
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

# Build a Release archive of Note.app, export an IPA, and (optionally)
# push it to App Store Connect for TestFlight distribution.
#
# Required env:
#   DEVELOPMENT_TEAM    Apple Developer Team ID (10-char alphanumeric).
#                       The team must already host the
#                       com.pingolin.note bundle id with App Attest,
#                       Push, Associated Domains, App Groups, and
#                       Keychain Sharing capabilities enabled.
#
# Optional env:
#   CONFIGURATION       Build configuration to archive (default: Release).
#                       `ReleaseDev` compiles the DEVELOPMENT hosts into an
#                       otherwise identical distribution-signed build, for
#                       TestFlight builds against the development servers.
#   BUILD_NUMBER        Overrides CURRENT_PROJECT_VERSION for this archive.
#                       App Store Connect rejects a build number it has
#                       already seen for the same version, and nothing here
#                       bumps the checked-in number, so a re-upload of the
#                       same commit needs a higher one here.
#
# Optional env (if any are set, all three are required → archive
# uploads to App Store Connect; otherwise the script stops at IPA):
#   ASC_KEY_ID          App Store Connect API key id
#                       (Users + Access → Keys in App Store Connect)
#   ASC_ISSUER_ID       Issuer id (same page)
#   ASC_KEY_PATH        Path to the AuthKey_<KEY_ID>.p8 file
#                       (downloaded once, can't be re-downloaded)
#
# Usage:
#   DEVELOPMENT_TEAM=ABCDE12345 ./archive.sh
#   DEVELOPMENT_TEAM=ABCDE12345 \
#     ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=00000000-... \
#     ASC_KEY_PATH=~/.appstoreconnect/AuthKey_XXXXXXXXXX.p8 \
#     ./archive.sh
#
# Outputs are written under ./build/:
#   build/Note.xcarchive    archive bundle (debug-symbols included)
#   build/export/Note.ipa   signed IPA ready for TestFlight
#   build/exportOptions.plist  the materialized export options used

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

PROJECT="Note.xcodeproj"
SCHEME="Note"
CONFIG="${CONFIGURATION:-Release}"
DESTINATION="generic/platform=iOS"

BUILD_DIR="$SCRIPT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Note.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/exportOptions.plist"

# --- Sanity checks ---------------------------------------------------------

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "error: DEVELOPMENT_TEAM is required (10-char Apple Developer Team ID)." >&2
  echo "  find it at https://developer.apple.com/account → Membership." >&2
  exit 64
fi

if [[ ! -f "$PROJECT/project.pbxproj" ]]; then
  echo "error: $PROJECT not found. Run 'xcodegen generate' first." >&2
  exit 65
fi

# Optional upload args — all-or-nothing.
UPLOAD=0
if [[ -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" || -n "${ASC_KEY_PATH:-}" ]]; then
  if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" || -z "${ASC_KEY_PATH:-}" ]]; then
    echo "error: set ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH together (or none)." >&2
    exit 64
  fi
  if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "error: ASC_KEY_PATH=$ASC_KEY_PATH not found." >&2
    exit 66
  fi
  UPLOAD=1
fi

# --- Workspace prep --------------------------------------------------------

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$EXPORT_DIR"

# Materialize exportOptions.plist with the team id substituted in.
# Keeping the source file under version control without the team id
# in it lets us share it openly; archive.sh writes the actual file
# the export step reads.
cp exportOptions.plist "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $DEVELOPMENT_TEAM" "$EXPORT_OPTIONS"

# --- Resolve packages so the archive step doesn't race the SPM cache ------

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -resolvePackageDependencies \
  -quiet

# --- Archive ---------------------------------------------------------------

# An explicit build number is passed as an xcodebuild override so the
# project file stays the record of what was last committed. The `[@]+`
# expansion keeps `set -u` quiet on an empty array under macOS bash 3.2.
BUILD_NUMBER_ARG=()
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  BUILD_NUMBER_ARG=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
fi

echo "==> Archiving $CONFIG build for iOS device${BUILD_NUMBER:+ (build $BUILD_NUMBER)}"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  ${BUILD_NUMBER_ARG[@]+"${BUILD_NUMBER_ARG[@]}"} \
  -allowProvisioningUpdates \
  archive

# --- Export IPA -----------------------------------------------------------

echo "==> Exporting IPA"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

IPA="$(find "$EXPORT_DIR" -maxdepth 2 -name '*.ipa' | head -n1)"
if [[ -z "$IPA" ]]; then
  echo "error: exportArchive succeeded but no IPA was produced under $EXPORT_DIR." >&2
  exit 70
fi
echo "==> IPA at $IPA"

# --- Optional: upload to App Store Connect --------------------------------

if [[ "$UPLOAD" -eq 1 ]]; then
  KEY_DIR="$(mktemp -d)"
  trap 'rm -rf "$KEY_DIR"' EXIT
  cp "$ASC_KEY_PATH" "$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"

  # altool reads the .p8 from API_PRIVATE_KEYS_DIR. The .p8 must be
  # named AuthKey_<KEY_ID>.p8 — the cp above renames it to that
  # canonical form regardless of where the user stored the original.
  echo "==> Uploading to App Store Connect (key $ASC_KEY_ID)"
  API_PRIVATE_KEYS_DIR="$KEY_DIR" xcrun altool \
    --upload-app \
    --type ios \
    --file "$IPA" \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" \
    --output-format xml

  echo "==> Upload complete. App Store Connect will email when processing finishes (5-30 min)."
  echo "    Promote to TestFlight from https://appstoreconnect.apple.com → My Apps → Note → TestFlight."
else
  cat <<MSG

Archive done; upload skipped (no ASC_* env vars).
To push to TestFlight manually:
  - Open Xcode → Window → Organizer → Archives, select this archive,
    click Distribute App → App Store Connect.
  - Or rerun this script with ASC_KEY_ID, ASC_ISSUER_ID, and
    ASC_KEY_PATH set; the .p8 must be the one downloaded from
    App Store Connect → Users + Access → Keys.

MSG
fi
