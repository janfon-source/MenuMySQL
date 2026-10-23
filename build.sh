#!/bin/zsh
# Builds 隨手MySQL.app without Xcode (Command Line Tools are enough).
# Usage:  ./build.sh            -> build/隨手MySQL.app
#         ./build.sh install    -> also copies it to /Applications
set -euo pipefail
cd "${0:A:h}"

APP=build/隨手MySQL.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

[[ -f MenuMySQL/AppIcon.icns ]] || swift tools/make_icon.swift

swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  MenuMySQL/*.swift -o "$APP/Contents/MacOS/MenuMySQL"

cp MenuMySQL/AppIcon.icns "$APP/Contents/Resources/"

# LSUIElement keeps the app out of the Dock and ⌘-Tab; it lives only in the menu bar.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>隨手MySQL</string>
	<key>CFBundleDisplayName</key><string>隨手MySQL</string>
	<key>CFBundleIdentifier</key><string>com.jeff.menumysql</string>
	<key>CFBundleExecutable</key><string>MenuMySQL</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>2026.a25</string>
	<key>CFBundleVersion</key><string>2026.a25</string>
	<key>CFBundleDevelopmentRegion</key><string>zh_TW</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# The keychain lets an app read the passwords it saved by the app's signature. An ad-hoc
# signature changes with every build, so the keychain would ask again each time; a certificate
# of one's own keeps the signature the same. It shares 隨手藏's (Keychain Access → Certificate
# Assistant → Create a Certificate, type Code Signing, named as below); without it the build is
# signed ad hoc.
IDENTITY="MenuHide Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
  echo "No \"$IDENTITY\" certificate: signed ad hoc, so the keychain will ask again for saved passwords after each build." >&2
fi
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  if pgrep -x MenuMySQL >/dev/null; then
    osascript -e 'tell application id "com.jeff.menumysql" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -x MenuMySQL >/dev/null || break; sleep 0.5; done
  fi
  rm -rf "/Applications/隨手MySQL.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/隨手MySQL.app"
fi
