#!/usr/bin/env bash
# Turn a `cmake --install` tree (prefix /usr) into a self-contained AppDir that
# also bundles glibc, so it runs on distributions older and newer than the one
# that built it. Usage: assemble-appdir.sh <AppDir>   (AppDir already holds usr/)
set -euo pipefail

APPDIR="$(realpath "$1")"
HERE="$(dirname "$(realpath "$0")")"
LIBDIR="$APPDIR/usr/lib"
MULTIARCH="$(gcc -print-multiarch)"
SYSLIB="/usr/lib/$MULTIARCH"

# Libraries that must come from the host because they are tied to its kernel
# driver or hardware stack. Everything else is bundled.
EXCLUDE='^(linux-vdso|libcuda|libnvidia|libnvcuvid|libGLX_.*|libEGL_.*|libgallium|libvulkan_.*|libdrm_.*)'

mkdir -p "$LIBDIR" "$APPDIR/lib64"

# --- Qt plugins -------------------------------------------------------------
QT_PLUGINS="$SYSLIB/qt6/plugins"
mkdir -p "$LIBDIR/qt6/plugins"
for d in platforms platforminputcontexts imageformats iconengines tls xcbglintegrations \
    wayland-decoration-client wayland-graphics-integration-client wayland-shell-integration \
    styles; do
    [ -d "$QT_PLUGINS/$d" ] && cp -a "$QT_PLUGINS/$d" "$LIBDIR/qt6/plugins/"
done

# --- dlopen()ed runtime pieces that ldd cannot see ---------------------------
mkdir -p "$LIBDIR/gconv"
cp -a "$SYSLIB"/gconv/. "$LIBDIR/gconv/"
for so in libnss_files.so.2 libnss_dns.so.2 libresolv.so.2 libxkbcommon-x11.so.0; do
    [ -e "$SYSLIB/$so" ] && cp -aL "$SYSLIB/$so" "$LIBDIR/"
done
[ -d "$SYSLIB/spa-0.2" ] && cp -a "$SYSLIB/spa-0.2" "$LIBDIR/"
[ -d "$SYSLIB/pipewire-0.3" ] && cp -a "$SYSLIB/pipewire-0.3" "$LIBDIR/"
if [ -d /usr/share/pipewire ]; then
    mkdir -p "$APPDIR/usr/share/pipewire"
    cp -a /usr/share/pipewire/. "$APPDIR/usr/share/pipewire/"
fi

# --- bundle the shared-library closure of every ELF in the AppDir ------------
export LD_LIBRARY_PATH="$LIBDIR"

is_elf() { [ "$(head -c4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; }

bundle_deps() {
    local f="$1" out lib
    out="$(ldd "$f" 2>/dev/null || true)"
    echo "$out" | awk '/=> \//{print $3}' | while read -r lib; do
        name="$(basename "$lib")"
        if [[ "$name" =~ $EXCLUDE ]]; then continue; fi
        [ -e "$LIBDIR/$name" ] || { cp -aL "$lib" "$LIBDIR/$name"; echo "$LIBDIR/$name"; }
    done
    if echo "$out" | grep -q 'not found'; then
        echo "::error::unresolved dependency for $f" >&2
        echo "$out" | grep 'not found' >&2
        return 1
    fi
}

queue="$(find "$APPDIR/usr" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) | while read -r f; do is_elf "$f" && echo "$f"; done)"
while [ -n "$queue" ]; do
    next=""
    while read -r f; do
        [ -n "$f" ] || continue
        new="$(bundle_deps "$f")"
        next="$next"$'\n'"$new"
    done <<<"$queue"
    queue="$(echo "$next" | sed '/^$/d')"
done

# --- the dynamic loader (see AppRun) ---------------------------------------
cp -aL "$SYSLIB/ld-linux-x86-64.so.2" "$APPDIR/lib64/ld-linux-x86-64.so.2"
rm -f "$LIBDIR/ld-linux-x86-64.so.2"
LOADER_HASH="$(sha256sum "$APPDIR/lib64/ld-linux-x86-64.so.2" | cut -c1-12)"
LOADER="/tmp/.obs-rust-appimage-$LOADER_HASH/ld-linux-x86-64.so.2"

# Every executable (not libraries) gets the bundled loader as interpreter.
find "$APPDIR/usr" -type f -perm -u+x ! -name '*.so' ! -name '*.so.*' | while read -r f; do
    is_elf "$f" || continue
    patchelf --print-interpreter "$f" >/dev/null 2>&1 || continue
    patchelf --set-interpreter "$LOADER" "$f"
    echo "interpreter patched: ${f#"$APPDIR"/}"
done

# --- desktop integration -----------------------------------------------------
sed "s|@LOADER@|$LOADER|" "$HERE/AppRun" >"$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"
cp "$APPDIR/usr/share/applications/com.obsproject.Studio.desktop" "$APPDIR/"
cp "$APPDIR/usr/share/icons/hicolor/256x256/apps/com.obsproject.Studio.png" "$APPDIR/"
ln -sf com.obsproject.Studio.png "$APPDIR/.DirIcon"

# --- sanity: nothing may resolve outside the AppDir except the excluded host libs
echo "::group::Libraries still resolved from the host"
# (the binary's interpreter now points at the not-yet-installed loader, so ask the bundled one)
"$APPDIR/lib64/ld-linux-x86-64.so.2" --library-path "$LIBDIR" --list "$APPDIR/usr/bin/obs" |
    grep -v "$APPDIR" | grep '=> /' || true
echo "::endgroup::"
du -sh "$APPDIR"
