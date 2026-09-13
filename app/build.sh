#!/bin/bash

# Build script for ClaudeUsageBar

# Steps are checked explicitly, one by one, rather than with a blanket `set -e`.
# That is a deliberate choice, not a necessity: `set -e` plus `|| true` on the
# four legitimately best-effort lines (dot_clean, the two `find -delete`
# cleanups, the PlistBuddy Add/Set fallback) would work too. Explicit checks are
# preferred here because each one can say what actually broke, which a blanket
# `set -e` cannot.
#
# Know the cost of this style: an unchecked line fails SILENTLY. That is the
# default here, and it is how an unchecked `cp Info.plist` once produced an
# unlaunchable bundle under a "Build successful!". Several lines below
# (mkdir -p, rm, > PkgInfo, chmod, xattr -cr) are still unchecked and are only
# covered incidentally by the assertions before signing. Check what you add.
#
# No pipeline in this script currently depends on pipefail; it is set so that
# one added later fails if any component fails, rather than reporting only the
# status of the last.
set -o pipefail

echo "Building ClaudeUsageBar..."

# SwiftUI macros (@State et al.) need the macro plugins that ship with Xcode.
# The CommandLineTools toolchain doesn't include libSwiftUIMacros.dylib, so
# compiling against it fails with "external macro implementation type ...
# could not be found". Route through Xcode's toolchain without changing the
# machine's global xcode-select setting.
# Test for the plugin itself, not just the directory: an exported DEVELOPER_DIR
# pointing at CommandLineTools is a real directory but still cannot build this.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFTUI_MACROS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "❌ Xcode not found at $DEVELOPER_DIR" >&2
    echo "   Install Xcode, or set DEVELOPER_DIR to your Xcode.app/Contents/Developer." >&2
    exit 1
elif [ ! -f "$SWIFTUI_MACROS" ]; then
    echo "❌ $DEVELOPER_DIR has no SwiftUI macro plugins (libSwiftUIMacros.dylib)." >&2
    echo "   This is usually a CommandLineTools path; building needs a full Xcode." >&2
    echo "   Set DEVELOPER_DIR to your Xcode.app/Contents/Developer and re-run." >&2
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

# Copy Info.plist. A bundle missing this still signs and verifies cleanly, but
# macOS will not launch it -- so a silent failure here is invisible until install.
cp Info.plist "$APP_PATH/Contents/" || { echo "❌ Failed to copy Info.plist" >&2; exit 1; }

# Create icon if it doesn't exist
if [ ! -f "ClaudeUsageBar.icns" ]; then
    echo "Creating app icon..."
    ./make_app_icon.sh >/dev/null || echo "⚠️  make_app_icon.sh failed; building without an app icon." >&2
fi

# Copy icon to Resources
if [ -f "ClaudeUsageBar.icns" ]; then
    cp ClaudeUsageBar.icns "$APP_PATH/Contents/Resources/" || { echo "❌ Failed to copy ClaudeUsageBar.icns" >&2; exit 1; }
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
# Not just "a file exists and lints": PlistBuddy CREATES Info.plist when it is
# absent, so a failed copy can leave a one-key plist that passes plutil -lint,
# signs cleanly, and still cannot launch. Require the keys that make it a bundle.
if [ ! -s "$APP_PATH/Contents/Info.plist" ] || ! plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null; then
    echo "❌ Missing or malformed Info.plist at $APP_PATH/Contents/Info.plist" >&2
    exit 1
fi
for key in CFBundleExecutable CFBundleIdentifier CFBundlePackageType; do
    if ! /usr/libexec/PlistBuddy -c "Print :$key" "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
        echo "❌ Info.plist is missing $key -- the bundle would not launch." >&2
        exit 1
    fi
done

# CFBundleExecutable must name the binary we actually built. codesign rejects a
# mismatch anyway, so this is not a correctness gate -- it is here so the failure
# reads as the naming mismatch it is, rather than as "signing failed".
PLIST_EXEC="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_PATH/Contents/Info.plist" 2>/dev/null)"
if [ "$PLIST_EXEC" != "ClaudeUsageBar" ]; then
    echo "❌ CFBundleExecutable is '$PLIST_EXEC' but the built binary is 'ClaudeUsageBar'." >&2
    exit 1
fi

# Ad-hoc signature. This build is for this machine only and is never
# distributed, so there is no Developer ID and no notarization step.
# --options runtime still enables the hardened runtime. No --deep: Apple
# documents it as a verification/repair flag rather than a signing one, and
# this bundle is a single flat executable with no nested code to recurse into.
if codesign --force --options runtime --sign - "$APP_PATH"; then
    echo "✅ App ad-hoc signed"
    codesign --verify --verbose=2 "$APP_PATH" || { echo "❌ Signature verification failed" >&2; exit 1; }
else
    echo "❌ Ad-hoc signing failed" >&2
    exit 1
fi

echo "Build successful!"
echo "App bundle created at: $APP_PATH"
