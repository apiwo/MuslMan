# shellcheck shell=bash
# MuslMan kmod.sh: build the NVIDIA kernel modules inside the bwrap sandbox
# against the host's own kernel headers (bind-mounted read-only). This is
# the only place the sandbox needs to see anything from the host kernel
# tree; it never touches the host's toolchain or root filesystem.

kmod_build() {
    # kmod_build <kernel-source-dir-on-host> <output-dir-on-host>
    local ksrc="$1" outdir="$2"
    local kver kbuild workdir

    sandbox_ensure_builddeps

    kver="$(uname -r)"
    kbuild="$(kernel_build_dir)" || die "no kernel build/headers tree found for running kernel ($kver). Expected /lib/modules/$kver/build or /usr/src/linux. Install your distro's kernel headers package first (see 'muslman doctor')."

    workdir="$(mktemp -d "$MUSLMAN_CACHE/kmod-build.XXXXXX")"
    ensure_dir "$workdir/src"
    ensure_dir "$workdir/out"
    cp -a "$ksrc/." "$workdir/src/"

    log "building NVIDIA kernel modules for kernel $kver (this can take a few minutes)..."
    sandbox_run_offline "$workdir" \
        "set -e; cd /work/src && make -j\"\$(nproc)\" modules SYSSRC=/kbuild IGNORE_CC_MISMATCH=1 && cp -v *.ko /work/out/" \
        --ro-bind "$kbuild" /kbuild \
        || die "kernel module build failed -- check that your kernel headers ($kbuild) match the running kernel ($kver) exactly"

    if ! ls "$workdir/out"/*.ko >/dev/null 2>&1; then
        die "kernel module build produced no .ko files"
    fi

    ensure_dir "$outdir"
    cp -a "$workdir/out/." "$outdir/"
    rm -rf "$workdir"
    ok "kernel modules built: $(cd "$outdir" && ls -- *.ko | tr '\n' ' ')"
}

kmod_install() {
    # kmod_install <built-ko-dir>
    local kodir="$1" kver moddir
    kver="$(uname -r)"
    moddir="/lib/modules/$kver/extra/muslman"
    ensure_dir "$moddir"
    for ko in "$kodir"/*.ko; do
        cp -a "$ko" "$moddir/"
        manifest_add file "$moddir/$(basename "$ko")"
    done
    manifest_add dir "$moddir"
    log "running depmod..."
    depmod -a "$kver" || warn "depmod exited non-zero -- module autoload may not work until you re-run it"
    ok "kernel modules installed to $moddir"
}
