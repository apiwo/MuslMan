# shellcheck shell=bash
# MuslMan glibc-compat.sh: fetch the sgerrand/alpine-pkg-glibc release.
#
# The proprietary NVIDIA userspace libraries are precompiled against glibc.
# A minimal shim (like gcompat) doesn't cover enough of the glibc symbol
# surface for something as large as the GL/EGL/Vulkan/CUDA stack. Instead
# we vendor a *real* glibc build: sgerrand/alpine-pkg-glibc packages an
# upstream Debian/Ubuntu-built glibc as an .apk specifically so glibc
# binaries can run unmodified on musl/Alpine systems. We extract its
# payload (it's a gzipped tar, same format as any .apk) into
# /opt/muslman/glibc-compat and later patchelf the NVIDIA blobs to use it
# as their interpreter/rpath. Pure download+extract, no compiling.

GLIBC_COMPAT_VERSION="${MUSLMAN_GLIBC_COMPAT_VERSION:-2.35-r1}"
GLIBC_COMPAT_RELEASE_TAG="${MUSLMAN_GLIBC_COMPAT_VERSION:-2.35-r1}"

glibc_compat_apk_url() {
    local ver="$1"
    echo "https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${ver}/glibc-${ver}.apk"
}

glibc_compat_fetch_and_extract() {
    # Prints the path to the extracted glibc-compat tree.
    local dest="$MUSLMAN_CACHE/glibc-compat-$GLIBC_COMPAT_VERSION"
    local apk="$MUSLMAN_CACHE/glibc-${GLIBC_COMPAT_VERSION}.apk"
    local url
    url="$(glibc_compat_apk_url "$GLIBC_COMPAT_VERSION")"

    if [ -d "$dest/lib" ] || [ -d "$dest/usr/glibc-compat/lib" ]; then
        echo "$dest"
        return 0
    fi

    ensure_dir "$MUSLMAN_CACHE"
    if [ ! -s "$apk" ]; then
        log "downloading glibc-compat runtime ($GLIBC_COMPAT_VERSION) from sgerrand/alpine-pkg-glibc..." >&2
        curl -fL --retry 3 -o "$apk.part" "$url" || die "failed to download $url"
        mv "$apk.part" "$apk"
    fi
    if ! gzip -t "$apk" 2>/dev/null; then
        rm -f "$apk"
        die "downloaded glibc-compat .apk failed integrity check: $apk"
    fi

    rm -rf "$dest"
    ensure_dir "$dest"
    # .apk is a concatenation of gzip streams (signature + control + data);
    # plain tar -xz happily reads through all of them and gives us the
    # real payload (usr/glibc-compat/...).
    tar -xzf "$apk" -C "$dest" 2>/dev/null || true

    if [ ! -d "$dest/usr/glibc-compat" ] && [ ! -d "$dest/lib" ]; then
        die "extracted glibc-compat archive did not contain the expected usr/glibc-compat tree -- alpine-pkg-glibc may have changed layout (dest=$dest)"
    fi
    ok "glibc-compat runtime extracted to $dest" >&2
    echo "$dest"
}

# Normalizes wherever the payload landed (usr/glibc-compat/{lib,usr/lib} or
# top-level lib/) into the final install layout under $MUSLMAN_PREFIX.
glibc_compat_install() {
    local extracted="$1" target="$MUSLMAN_PREFIX/glibc-compat"
    ensure_dir "$target/lib"
    ensure_dir "$target/usr/lib"

    local src_lib=""
    if [ -d "$extracted/usr/glibc-compat/lib" ]; then
        src_lib="$extracted/usr/glibc-compat/lib"
    elif [ -d "$extracted/lib" ]; then
        src_lib="$extracted/lib"
    fi
    [ -n "$src_lib" ] || die "could not locate glibc-compat lib directory inside $extracted"

    cp -a "$src_lib/." "$target/lib/"
    manifest_add dir "$target"

    # Some layouts also ship usr/glibc-compat/lib64 or usr/lib -- copy if present.
    for extra in "$extracted/usr/glibc-compat/usr/lib" "$extracted/usr/glibc-compat/lib64"; do
        [ -d "$extra" ] && cp -a "$extra/." "$target/usr/lib/" 2>/dev/null || true
    done

    # The dynamic linker itself must be at a predictable, absolute path
    # since it gets baked into every patched binary's PT_INTERP.
    if [ ! -e "$target/lib/ld-linux-x86-64.so.2" ]; then
        local found
        found="$(find "$target" -name 'ld-linux-x86-64.so.2' -print -quit 2>/dev/null)"
        [ -n "$found" ] || die "glibc-compat install is missing ld-linux-x86-64.so.2 (interpreter) -- cannot proceed"
        ln -sf "$found" "$target/lib/ld-linux-x86-64.so.2"
    fi

    ok "glibc-compat runtime installed at $target"
    echo "$target"
}
