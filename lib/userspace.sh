# shellcheck shell=bash
# MuslMan userspace.sh: patchelf pass over the NVIDIA payload's precompiled
# glibc-linked libraries/binaries so they can run against the vendored
# glibc-compat runtime on a musl host. Runs inside the offline sandbox.

# Files from the .run payload we actually want to ship. Everything else
# (32-bit compat libs, installer scripts, docs, source we already built
# separately) is left behind.
USERSPACE_LIB_GLOBS=(
    "libcuda.so*"
    "libEGL_nvidia.so*"
    "libGLX_nvidia.so*"
    "libGLESv1_CM_nvidia.so*"
    "libGLESv2_nvidia.so*"
    "libnvidia-eglcore.so*"
    "libnvidia-glcore.so*"
    "libnvidia-glsi.so*"
    "libnvidia-glvkspirv.so*"
    "libnvidia-allocator.so*"
    "libnvidia-cfg.so*"
    "libnvidia-ml.so*"
    "libnvidia-ptxjitcompiler.so*"
    "libnvidia-rtcore.so*"
    "libnvidia-nvvm.so*"
    "libnvidia-tls.so*"
    "libnvoptix.so*"
    "libnvidia-vulkan-producer.so*"
    "libnvidia-fbc.so*"
    "libnvidia-encode.so*"
)
USERSPACE_BIN_LIST=(
    "nvidia-smi"
    "nvidia-modprobe"
    "nvidia-cuda-mps-control"
    "nvidia-cuda-mps-server"
    "nvidia-debugdump"
    "nvidia-persistenced"
)
USERSPACE_XORG_LIST=(
    "nvidia_drv.so"
)

userspace_collect() {
    # userspace_collect <payload-dir> <staging-dir>
    local payload="$1" staging="$2" pattern f
    ensure_dir "$staging/lib"
    ensure_dir "$staging/bin"
    ensure_dir "$staging/xorg-modules"

    for pattern in "${USERSPACE_LIB_GLOBS[@]}"; do
        for f in "$payload"/$pattern; do
            [ -e "$f" ] || continue
            cp -a "$f" "$staging/lib/"
        done
    done
    for f in "${USERSPACE_BIN_LIST[@]}"; do
        [ -e "$payload/$f" ] && cp -a "$payload/$f" "$staging/bin/"
    done
    for f in "${USERSPACE_XORG_LIST[@]}"; do
        [ -e "$payload/$f" ] && cp -a "$payload/$f" "$staging/xorg-modules/"
    done

    if [ -z "$(ls -A "$staging/lib" 2>/dev/null)" ]; then
        die "no NVIDIA userspace libraries matched in $payload -- unexpected .run payload layout"
    fi
}

# Patches every ELF file under $1 in place, inside the offline sandbox,
# to use the glibc-compat runtime at $2 (a host path, bind-mounted in).
userspace_patchelf() {
    local staging="$1" glibc_compat="$2"
    sandbox_ensure_builddeps

    log "patching NVIDIA userspace binaries to use glibc-compat runtime..."
    sandbox_run_offline "$staging" '
        set -e
        cd /work
        count=0
        skipped=0
        for f in $(find lib bin xorg-modules -type f 2>/dev/null); do
            # Only touch real ELF files.
            if ! head -c4 "$f" | grep -qU "$(printf "\x7fELF")" 2>/dev/null; then
                continue
            fi
            interp="$(patchelf --print-interpreter "$f" 2>/dev/null || true)"
            if [ -z "$interp" ]; then
                skipped=$((skipped+1))
                continue
            fi
            case "$interp" in
                */ld-linux-x86-64.so.2|*/ld-linux.so.2)
                    patchelf --set-interpreter /glibc-compat/lib/ld-linux-x86-64.so.2 \
                             --set-rpath "/glibc-compat/lib:/glibc-compat/usr/lib:\$ORIGIN:\$ORIGIN/../lib" \
                             "$f" && count=$((count+1))
                    ;;
                *)
                    skipped=$((skipped+1))
                    ;;
            esac
        done
        echo "patchelf: patched $count file(s), skipped $skipped (not glibc-linked or not ELF)"
    ' --ro-bind "$glibc_compat" /glibc-compat \
        || die "patchelf pass failed"

    ok "userspace libraries patched for glibc-compat"
}

userspace_install() {
    # userspace_install <staging-dir>
    local staging="$1" prefix="$MUSLMAN_PREFIX/nvidia"
    ensure_dir "$prefix/lib"
    ensure_dir "$prefix/bin"
    ensure_dir "$prefix/xorg-modules"

    cp -a "$staging/lib/." "$prefix/lib/"
    cp -a "$staging/bin/." "$prefix/bin/" 2>/dev/null || true
    cp -a "$staging/xorg-modules/." "$prefix/xorg-modules/" 2>/dev/null || true
    chmod +x "$prefix/bin/"* 2>/dev/null || true

    manifest_add dir "$prefix"
    ok "NVIDIA userspace libraries installed to $prefix"
}
