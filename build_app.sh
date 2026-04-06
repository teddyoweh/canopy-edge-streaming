#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
#  Build Canopy Streamer.app
#
#  Run this on a Mac to assemble the .app bundle. It creates:
#    CanopyStreamer.app/
#      Contents/
#        Info.plist          ← camera permission + app metadata
#        MacOS/
#          CanopyStreamer     ← main launcher (executable bash script)
#        Resources/
#          server.py          ← Flask streaming server
#          requirements.txt   ← Python dependencies
#          gui.py             ← tkinter status window
#
#  Usage:
#    chmod +x build_app.sh && ./build_app.sh
#
#  Output:
#    ./CanopyStreamer.app  (ready to double-click or drag to /Applications)
# ─────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="CanopyStreamer"
APP_DIR="$SCRIPT_DIR/${APP_NAME}.app"

echo ""
echo "=== Building ${APP_NAME}.app ==="
echo ""

# Clean previous build
rm -rf "$APP_DIR"

# Create .app structure
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# ── Info.plist ──
cp "$SCRIPT_DIR/app_bundle/Info.plist" "$APP_DIR/Contents/Info.plist"
echo "  ✓ Info.plist (camera permission, app metadata)"

# ── Main executable (compiled native wrapper → bash script) ──
# macOS Gatekeeper blocks .app bundles with a shell script as the main binary.
# Compile a tiny C launcher that exec's the real bash script from Resources.
cp "$SCRIPT_DIR/app_bundle/CanopyStreamer" "$APP_DIR/Contents/Resources/launcher.sh"
chmod +x "$APP_DIR/Contents/Resources/launcher.sh"

cat > /tmp/_canopy_launcher.c << 'LAUNCHERC'
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <mach-o/dyld.h>
int main(int argc, char *argv[]) {
    char exe[4096];
    uint32_t size = sizeof(exe);
    _NSGetExecutablePath(exe, &size);

    /* Resolve to absolute path */
    char *real = realpath(exe, NULL);
    if (!real) real = exe;

    /* real = .../CanopyStreamer.app/Contents/MacOS/CanopyStreamer
       We want .../CanopyStreamer.app/Contents/Resources/launcher.sh
       Strategy: find last "/Contents/MacOS/" and replace MacOS/CanopyStreamer */
    char *marker = strstr(real, "/Contents/MacOS/");
    if (!marker) {
        fprintf(stderr, "Cannot find /Contents/MacOS/ in path: %s\n", real);
        return 1;
    }

    /* Build script path */
    char script[4096];
    size_t prefix_len = (size_t)(marker - real);
    snprintf(script, sizeof(script), "%.*s/Contents/Resources/launcher.sh", (int)prefix_len, real);

    execv("/bin/bash", (char *[]){ "bash", script, NULL });
    perror("exec failed");
    return 1;
}
LAUNCHERC

# Build universal binary (arm64 + x86_64) targeting macOS 10.15+ so it works on ANY Mac
cc -O2 -arch arm64 -mmacosx-version-min=11.0 -o /tmp/_canopy_arm64 /tmp/_canopy_launcher.c 2>/dev/null
cc -O2 -arch x86_64 -mmacosx-version-min=10.15 -o /tmp/_canopy_x86 /tmp/_canopy_launcher.c 2>/dev/null
if [ -f /tmp/_canopy_arm64 ] && [ -f /tmp/_canopy_x86 ]; then
    lipo -create /tmp/_canopy_arm64 /tmp/_canopy_x86 -output "$APP_DIR/Contents/MacOS/CanopyStreamer"
    echo "  ✓ Universal binary (arm64 + x86_64)"
elif [ -f /tmp/_canopy_arm64 ]; then
    cp /tmp/_canopy_arm64 "$APP_DIR/Contents/MacOS/CanopyStreamer"
    echo "  ✓ Native launcher (arm64 only)"
else
    echo "  ⊘ cc failed, falling back to script executable"
    cp "$SCRIPT_DIR/app_bundle/CanopyStreamer" "$APP_DIR/Contents/MacOS/CanopyStreamer"
    chmod +x "$APP_DIR/Contents/MacOS/CanopyStreamer"
fi
rm -f /tmp/_canopy_launcher.c /tmp/_canopy_arm64 /tmp/_canopy_x86

# ── Resources (server files) ──
cp "$SCRIPT_DIR/server.py"        "$APP_DIR/Contents/Resources/server.py"
cp "$SCRIPT_DIR/requirements.txt" "$APP_DIR/Contents/Resources/requirements.txt"
cp "$SCRIPT_DIR/app_bundle/gui.py" "$APP_DIR/Contents/Resources/gui.py"
echo "  ✓ Server + GUI files"

# ── Generate a simple app icon (orange circle with C) ──
# Uses Python to create a basic .icns if possible, otherwise skips
if command -v python3 &>/dev/null; then
    python3 - "$APP_DIR/Contents/Resources" << 'ICONEOF' 2>/dev/null || true
import sys, os
try:
    from PIL import Image, ImageDraw, ImageFont

    sizes = [16, 32, 64, 128, 256, 512, 1024]
    icon_dir = sys.argv[1]
    iconset_dir = os.path.join(icon_dir, "AppIcon.iconset")
    os.makedirs(iconset_dir, exist_ok=True)

    for size in sizes:
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)

        # Orange circle
        margin = size // 10
        draw.ellipse([margin, margin, size - margin, size - margin],
                     fill=(255, 95, 15, 255))

        # White "C" letter
        try:
            font = ImageFont.truetype("/System/Library/Fonts/SFCompact.ttf", int(size * 0.5))
        except:
            try:
                font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", int(size * 0.5))
            except:
                font = ImageFont.load_default()

        bbox = draw.textbbox((0, 0), "C", font=font)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        tx = (size - tw) // 2 - bbox[0]
        ty = (size - th) // 2 - bbox[1]
        draw.text((tx, ty), "C", fill=(255, 255, 255, 255), font=font)

        img.save(os.path.join(iconset_dir, f"icon_{size}x{size}.png"))
        if size <= 512:
            img2 = img.resize((size * 2, size * 2), Image.LANCZOS)
            img2.save(os.path.join(iconset_dir, f"icon_{size}x{size}@2x.png"))

    # Convert iconset to icns
    os.system(f'iconutil -c icns "{iconset_dir}" -o "{icon_dir}/AppIcon.icns" 2>/dev/null')

    # Clean up iconset
    import shutil
    shutil.rmtree(iconset_dir, ignore_errors=True)

    if os.path.exists(os.path.join(icon_dir, "AppIcon.icns")):
        print("  ✓ App icon")
    else:
        print("  ⊘ Icon generation skipped (iconutil unavailable)")
except ImportError:
    print("  ⊘ Icon generation skipped (Pillow not installed — optional)")
ICONEOF
fi

# ── Code-sign + clear quarantine (skip errors silently) ──
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null && echo "  ✓ Signed" || true
xattr -cr "$APP_DIR" 2>/dev/null || true

# ── Create DMG for distribution ──
DMG_PATH="$SCRIPT_DIR/${APP_NAME}.dmg"
rm -f "$DMG_PATH"

# Create staging directory
DMG_STAGING="$SCRIPT_DIR/.dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Build the DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" 2>/dev/null && \
    echo "  ✓ ${APP_NAME}.dmg created" || \
    echo "  ⊘ DMG creation failed"

rm -rf "$DMG_STAGING"

echo ""
echo "=== Build complete! ==="
echo ""
echo "  ${APP_NAME}.app — ready to use"
echo "  ${APP_NAME}.dmg — send this to anyone"
echo ""
echo "  On first open: Right-click > Open > click 'Open' in the popup."
echo "  After that it opens normally with a double-click."
echo ""
echo "  First run will install Python dependencies (takes ~1 min)."
echo "  macOS will prompt for camera permission — click Allow."
echo ""

# If running on macOS, offer to open it
if [ "$(uname -s)" = "Darwin" ]; then
    echo -n "  Open the app now? (y/N): "
    read -r OPEN_NOW
    if [[ "$OPEN_NOW" == "y" || "$OPEN_NOW" == "Y" ]]; then
        open "$APP_DIR"
    fi
fi
