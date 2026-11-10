#!/usr/bin/env bash
# ==============================================================================
# build_and_sign.sh
# Production Code Signing and Notarization Pipeline for SystemCleaner
# ==============================================================================
set -euo pipefail

DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Your Studio (TEAMID1234)}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-AC_PASSWORD}"
APP_PATH="build/Release/SystemCleaner.app"
HELPER_PATH="$APP_PATH/Contents/Library/LaunchDaemons/com.cleaner.helper"
ZIP_PATH="build/Release/SystemCleaner.zip"

echo "==> 1. Sign Privileged Helper Tool (Unsandboxed Root Tool)"
codesign --force --options runtime --timestamp \
         --entitlements "Config/Helper.entitlements" \
         --sign "$DEVELOPER_ID" "$HELPER_PATH"

echo "==> 2. Sign Main App Bundle Deeply"
codesign --force --options runtime --timestamp \
         --entitlements "Config/App.entitlements" \
         --sign "$DEVELOPER_ID" "$APP_PATH"

echo "==> 3. Verify Code Signatures and Designated Requirements"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type exec --verbose=2 "$APP_PATH"

echo "==> 4. Create Archive for Notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> 5. Submit to Apple Notary Service via notarytool"
xcrun notarytool submit "$ZIP_PATH" \
      --keychain-profile "$KEYCHAIN_PROFILE" \
      --wait

echo "==> 6. Staple Notarization Ticket"
xcrun stapler staple "$APP_PATH"

echo "==> SUCCESS: SystemCleaner signed, notarized, and stapled!"
