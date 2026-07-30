# shellcheck shell=bash
# MuslMan egl-integration.sh: build NVIDIA's open-source EGL/Wayland and
# EGL/GBM glue libraries natively for musl inside the sandbox. Unlike the
# GL/EGL/Vulkan core libraries, these are small permissively-licensed C
# projects NVIDIA publishes on GitHub -- we build them fresh rather than
# trying to patchelf a glibc build, so the Wayland/DRM/KMS path (Sway,
# wlroots compositors, etc.) has no glibc dependency at all.

EGL_WAYLAND_VERSION="${MUSLMAN_EGL_WAYLAND_VERSION:-1.1.18}"
EGL_GBM_VERSION="${MUSLMAN_EGL_GBM_VERSION:-1.1.2}"

egl_wayland_url() { echo "https://github.com/NVIDIA/egl-wayland/archive/refs/tags/${EGL_WAYLAND_VERSION}.tar.gz"; }
egl_gbm_url()     { echo "https://github.com/NVIDIA/egl-gbm/archive/refs/tags/${EGL_GBM_VERSION}.tar.gz"; }

_fetch_source_tarball() {
    # _fetch_source_tarball <url> <dest-file>
    local url="$1" dest="$2"
    if [ ! -s "$dest" ]; then
        log "downloading $(basename "$dest")..." >&2
        curl -fL --retry 3 -o "$dest.part" "$url" || die "failed to download $url"
        mv "$dest.part" "$dest"
    fi
    gzip -t "$dest" 2>/dev/null || die "downloaded source tarball failed integrity check: $dest"
}

egl_integration_build() {
    # Builds both libraries, prints the dir containing the resulting .so files.
    sandbox_ensure_builddeps

    local outdir="$MUSLMAN_CACHE/egl-integration-out"
    rm -rf "$outdir"
    ensure_dir "$outdir"

    local ew_tar="$MUSLMAN_CACHE/egl-wayland-${EGL_WAYLAND_VERSION}.tar.gz"
    local eg_tar="$MUSLMAN_CACHE/egl-gbm-${EGL_GBM_VERSION}.tar.gz"
    _fetch_source_tarball "$(egl_wayland_url)" "$ew_tar"
    _fetch_source_tarball "$(egl_gbm_url)" "$eg_tar"

    local workdir
    workdir="$(mktemp -d "$MUSLMAN_CACHE/egl-build.XXXXXX")"
    ensure_dir "$workdir/src"
    ensure_dir "$workdir/out"
    tar -xzf "$ew_tar" -C "$workdir/src"
    tar -xzf "$eg_tar" -C "$workdir/src"

    local ew_dir eg_dir
    ew_dir="$(find "$workdir/src" -maxdepth 1 -iname 'egl-wayland-*' -print -quit)"
    eg_dir="$(find "$workdir/src" -maxdepth 1 -iname 'egl-gbm-*' -print -quit)"
    [ -n "$ew_dir" ] || die "egl-wayland source not found after extraction"
    [ -n "$eg_dir" ] || die "egl-gbm source not found after extraction"

    log "building egl-wayland and egl-gbm for musl (native, no glibc dependency)..."
    sandbox_run_offline "$workdir" '
        set -e
        cd "/work/src/'"$(basename "$ew_dir")"'"
        meson setup /work/build-egl-wayland -Dprefix=/work/out --buildtype=release
        ninja -C /work/build-egl-wayland install

        cd "/work/src/'"$(basename "$eg_dir")"'"
        meson setup /work/build-egl-gbm -Dprefix=/work/out --buildtype=release
        ninja -C /work/build-egl-gbm install
    ' || die "egl-wayland/egl-gbm build failed"

    ensure_dir "$outdir"
    cp -a "$workdir/out/." "$outdir/"
    rm -rf "$workdir"

    if [ -z "$(find "$outdir" -name '*.so*' -print -quit 2>/dev/null)" ]; then
        die "egl-wayland/egl-gbm build produced no shared libraries"
    fi
    ok "egl-wayland/egl-gbm built"
    echo "$outdir"
}

egl_integration_install() {
    # egl_integration_install <build-out-dir>
    local outdir="$1" prefix="$MUSLMAN_PREFIX/nvidia"
    ensure_dir "$prefix/lib"
    find "$outdir" -name '*.so*' -exec cp -a {} "$prefix/lib/" \;
    manifest_add dir "$prefix"
    ok "egl-wayland/egl-gbm installed to $prefix/lib"
}
