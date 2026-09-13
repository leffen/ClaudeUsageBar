#!/bin/bash

# Build script for ClaudeUsageBar

# Individual steps are checked explicitly rather than with a blanket `set -e`:
# several lines below are legitimately best-effort (dot_clean, the `find -delete`
# cleanups, the PlistBuddy Add/Set fallback) and a non-zero exit is normal there.
set -o pipefail

echo "Building ClaudeUsageBar..."

# SwiftUI macros (@State et al.) need the macro plugins that ship with Xcode.
# The CommandLineTools toolchain doesn't include libSwiftUIMacros.dylib, so
# compiling against it fails with "external macro implementation type ...
# could not be found". Route through Xcode's toolchain without changing the
# machine's global xcode-select setting.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "❌ Xcode not found at $DEVELOPER_DIR" >&2
    echo "   Install Xcode, or set DEVELOPER_DIR to your Xcode.app/Contents/Developer." >&2
    exit 1
fi

# Create fresh build directory (delete any stale build to avoid accumulated xattrs
# from prior signs, which can cause "resource fork / detritus" errors on codesign).
rm -rf build
mkdir -p build

# Create app bundle structure first
APP_NAME="ClaudeUsageBar.app"
APP_PATH="build/$APP_NAME"

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy Info.plist
cp Info.plist "$APP_PATH/Contents/"

# Create icon if it doesn't exist
if [ ! -f "ClaudeUsageBar.icns" ]; then
    echo "Creating app icon..."
    ./make_app_icon.sh >/dev/null 2>&1
fi

# Copy icon to Resources
if [ -f "ClaudeUsageBar.icns" ]; then
    cp ClaudeUsageBar.icns "$APP_PATH/Contents/Resources/"
    # Update Info.plist to reference icon
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string ClaudeUsageBar" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ClaudeUsageBar" "$APP_PATH/Contents/Info.plist"
fi

# Compile the Swift app for arm64
xcrun swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    ClaudeUsageBar.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target arm64-apple-macos12.0 || { echo "❌ Compile failed for arm64" >&2; exit 1; }

# Compile for x86_64 (Intel)
xcrun swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64" \
    ClaudeUsageBar.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target x86_64-apple-macos12.0 || { echo "❌ Compile failed for x86_64" >&2; exit 1; }

# Create universal binary
lipo -create -output "$APP_PATH/Contents/MacOS/ClaudeUsageBar" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64" || { echo "❌ lipo failed to create the universal binary" >&2; exit 1; }

# Clean up individual arch binaries
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64"
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64"

# Create PkgInfo file
echo -n "APPL????" > "$APP_PATH/Contents/PkgInfo"

# Set proper permissions first
chmod 755 "$APP_PATH/Contents/MacOS/ClaudeUsageBar"

# Clean any "detritus" that codesign rejects: extended attributes, ._files, .DS_Store
xattr -cr "$APP_PATH"
find "$APP_PATH" -name '._*' -delete 2>/dev/null
find "$APP_PATH" -name '.DS_Store' -delete 2>/dev/null
dot_clean "$APP_PATH" 2>/dev/null

# Never sign an empty bundle: assert the executable is really there. Without this
# the script happily signed a bundle whose MacOS/ directory was empty and still
# reported "Build successful!".
if [ ! -s "$APP_PATH/Contents/MacOS/ClaudeUsageBar" ] || [ ! -x "$APP_PATH/Contents/MacOS/ClaudeUsageBar" ]; then
    echo "❌ No executable in the bundle at $APP_PATH/Contents/MacOS/ClaudeUsageBar" >&2
    exit 1
fi

# Ad-hoc signature. This build is for this machine only and is never
# distributed, so there is no Developer ID and no notarization step.
# --options runtime still enables the hardened runtime.
if codesign --force --deep --options runtime --sign - "$APP_PATH"; then
    echo "✅ App ad-hoc signed"
    codesign --verify --verbose=2 "$APP_PATH" || { echo "❌ Signature verification failed" >&2; exit 1; }
else
    echo "❌ Ad-hoc signing failed" >&2
    exit 1
fi

echo "Build successful!"
echo "App bundle created at: $APP_PATH"
