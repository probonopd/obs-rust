#!/usr/bin/env bash
# Portability test for the OBS Studio AppImage. Run inside a stock distribution
# container that has NO OBS dependencies installed:
#   test-appimage.sh <path-to.AppImage> <output-dir>
# Only generic test infrastructure (X server, window manager, screenshot tools,
# fonts) and a stand-in for the host GPU driver (Mesa) are installed here; every
# library OBS needs must come out of the AppImage.
set -euo pipefail

APPIMAGE="$(realpath "$1")"
OUT="$(realpath -m "${2:-.}")"
mkdir -p "$OUT"
cd "$(mktemp -d)"

echo "::group::Container: $(. /etc/os-release && echo "$PRETTY_NAME"), $(ldd --version 2>&1 | head -1)"
echo "::endgroup::"

echo "::group::Install test infrastructure"
. /etc/os-release
case "${ID_LIKE:-} ${ID}" in
*debian* | *ubuntu*)
    export DEBIAN_FRONTEND=noninteractive
    # Keep downloaded .debs (the images delete them) so the CI package cache works.
    rm -f /etc/apt/apt.conf.d/docker-clean
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true"; APT::Keep-Downloaded-Packages "true";' \
        >/etc/apt/apt.conf.d/99keep
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        ca-certificates xvfb icewm x11-utils imagemagick fonts-dejavu-core gdb procps \
        libgl1-mesa-dri libglx-mesa0 libegl-mesa0 >/dev/null
    ;;
*fedora* | *rhel*)
    dnf install -y -q --setopt=install_weak_deps=False --setopt=keepcache=1 \
        xorg-x11-server-Xvfb icewm xwininfo ImageMagick \
        dejavu-sans-fonts gdb procps-ng mesa-dri-drivers mesa-libGL mesa-libEGL >/dev/null
    ;;
*)
    echo "::error::unsupported test distribution: $PRETTY_NAME"
    exit 1
    ;;
esac
echo "::endgroup::"

# Make sure the container really does lack what the AppImage must bring along.
for lib in libQt6Core.so.6 libavcodec.so libobs.so.30 libx264.so; do
    if ldconfig -p | grep -q "$lib"; then
        echo "::error::test container unexpectedly provides $lib"
        exit 1
    fi
done

chmod +x "$APPIMAGE"

echo "::group::AppImage runs through its own runtime (no FUSE in containers)"
VERSION_OUT="$(APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGE" --version 2>&1)" || {
    echo "$VERSION_OUT"
    echo "::error::obs --version failed"
    exit 1
}
echo "$VERSION_OUT"
echo "::endgroup::"

"$APPIMAGE" --appimage-extract >/dev/null
APPDIR="$PWD/squashfs-root"

Xvfb :99 -screen 0 1280x800x24 &
XVFB_PID=$!
sleep 2
export DISPLAY=:99
# Some toolkits only paint after a window manager completes the map handshake.
icewm >/dev/null 2>&1 &
WM_PID=$!
sleep 2

export HOME="$PWD/home"
mkdir -p "$HOME/.config/obs-studio" # OBS only creates one directory level at a time
export QT_QPA_PLATFORM=xcb
export QT_ACCESSIBILITY=0
export DBUS_SESSION_BUS_ADDRESS=disabled:
export LIBGL_ALWAYS_SOFTWARE=1 # no GPU in CI; Mesa llvmpipe from the host stands in for the driver

"$APPDIR/AppRun" --disable-shutdown-check --verbose >"$OUT/obs-stdout.log" 2>&1 &
APP_PID=$!

WINDOW_FOUND=0
RENDERED=0
for _ in $(seq 1 15); do
    sleep 2
    kill -0 "$APP_PID" 2>/dev/null || break
    # A real window owned by OBS (not just the window manager's own chrome).
    # (capture first: `grep -q` closing the pipe early fails the pipeline under pipefail)
    WINDOWS="$(xwininfo -tree -root 2>/dev/null || true)"
    if grep -qE '"OBS [0-9]|"obs"' <<<"$WINDOWS"; then
        WINDOW_FOUND=1
        import -window root "$OUT/screenshot.png"
        STDDEV="$(identify -format '%[fx:standard_deviation]' "$OUT/screenshot.png")"
        echo "OBS window found, frame stddev: $STDDEV"
        if awk -v v="$STDDEV" 'BEGIN{exit !(v > 0.02)}'; then
            RENDERED=1
            break
        fi
    fi
done

echo "::group::Diagnostics"
xwininfo -tree -root 2>&1 | head -40 || true
if kill -0 "$APP_PID" 2>/dev/null; then
    # Libraries actually mapped into the running process: the core stack must be bundled.
    echo "Libraries mapped from outside the AppImage:"
    grep -o '/[^ ]*\.so[^ ]*' "/proc/$APP_PID/maps" | sort -u | grep -v "$APPDIR" | grep -v '/tmp/.obs-rust-appimage-' || true
    MISSING=0
    for lib in libc.so.6 libstdc++.so.6 libQt6Core.so libQt6Widgets.so libavcodec.so libobs.so libX11.so libxcb.so; do
        if ! grep -o '/[^ ]*' "/proc/$APP_PID/maps" | grep "/$lib" | grep -q "$APPDIR"; then
            echo "::error::$lib was not loaded from inside the AppImage"
            MISSING=1
        fi
    done
else
    echo "OBS has already exited"
    MISSING=1
fi
echo "::endgroup::"

LOG="$(ls -1 "$HOME"/.config/obs-studio/logs/* 2>/dev/null | tail -1 || true)"
if [ -n "$LOG" ]; then
    cp "$LOG" "$OUT/obs.log"
    echo "::group::OBS log"
    cat "$LOG"
    echo "::endgroup::"
fi
echo "::group::OBS stdout/stderr"
cat "$OUT/obs-stdout.log"
echo "::endgroup::"

if kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
fi
kill "$WM_PID" "$XVFB_PID" 2>/dev/null || true

[ "$WINDOW_FOUND" -eq 1 ] || { echo "::error::no OBS window ever appeared"; exit 1; }
[ "$RENDERED" -eq 1 ] || { echo "::error::OBS window exists but the screen stayed blank"; exit 1; }
[ "$MISSING" -eq 0 ] || exit 1
if [ -n "$LOG" ] && grep -qiE 'Failed to initialize video|Failed to load.*libobs-opengl' "$LOG"; then
    grep -iE 'Failed to' "$LOG"
    echo "::error::OBS reported a fatal initialisation failure"
    exit 1
fi
echo "OBS AppImage passed on $PRETTY_NAME"
