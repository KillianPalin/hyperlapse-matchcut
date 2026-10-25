#!/bin/zsh
# Builds the app with swiftc (no Xcode project) and installs it in /Applications as "Hyperlapse/Match cut".
#   ./Tools/build.sh            -> build + install
#   ./Tools/build.sh noinstall  -> build only, in .build/HYPERLAPSE.app
set -e
ROOT=${0:A:h:h}
cd "$ROOT"
ARCH=$(uname -m)
BUILD="$ROOT/.build"
APP="$BUILD/HYPERLAPSE.app"
mkdir -p "$BUILD"

if [[ ! -f $BUILD/AppIcon.icns || Tools/make_icon.swift -nt $BUILD/AppIcon.icns ]]; then
  rm -rf "$BUILD/AppIcon.iconset"
  swift Tools/make_icon.swift "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi

swiftc -O -swift-version 5 -parse-as-library -target $ARCH-apple-macosx14.0 -module-name Hyperlapse \
  Sources/*.swift -o "$BUILD/Hyperlapse"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BUILD/Hyperlapse" "$APP/Contents/MacOS/Hyperlapse"
cp Resources/Fonts/*.ttf Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Hyperlapse</string>
  <key>CFBundleName</key><string>Hyperlapse/Match cut</string>
  <key>CFBundleDisplayName</key><string>Hyperlapse/Match cut</string>
  <key>CFBundleIdentifier</key><string>com.killian.hyperlapse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
codesign --force --deep -s "${IDENTITY:--}" "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "Construit : $APP"

if [[ $1 != noinstall ]]; then
  # Finder shows a ":" of a file name as "/": the app appears as "Hyperlapse/Match cut".
  DEST="/Applications/Hyperlapse:Match cut.app"
  rm -rf "/Applications/Repère.app" "/Applications/HYPERLAPSE.app"  # former names of the app
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installé : $DEST (affichée « Hyperlapse/Match cut »)"
fi
