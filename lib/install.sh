# shellcheck shell=bash
# MuslMan install.sh: orchestrates the full install. All compiling happens
# via lib/sandbox.sh's offline bwrap sandbox; this file's own job is
# fetching, calling the build steps in order, and wiring the results into
# the host system under $MUSLMAN_PREFIX + a handful of well-known config
# locations, all tracked in the manifest.

render_template() {
    # render_template <template-file> -> stdout, with @@PREFIX@@ substituted
    sed "s#@@PREFIX@@#$MUSLMAN_PREFIX#g" "$1"
}

install_configs() {
    local tmpl="$MUSLMAN_ROOT/config/templates"

    install_managed_file /etc/modprobe.d/muslman-nvidia.conf \
        "$(render_template "$tmpl/modprobe.conf.tmpl")"

    install_managed_file /etc/X11/xorg.conf.d/20-muslman-nvidia.conf \
        "$(render_template "$tmpl/xorg.conf.tmpl")"

    ensure_dir /usr/share/glvnd/egl_vendor.d
    install_managed_file /usr/share/glvnd/egl_vendor.d/10_nvidia.json \
        "$(render_template "$tmpl/egl-vendor.json.tmpl")"

    ensure_dir /etc/vulkan/icd.d
    install_managed_file /etc/vulkan/icd.d/nvidia_icd.json \
        "$(render_template "$tmpl/vulkan-icd.json.tmpl")"

    ensure_dir /etc/udev/rules.d
    install_managed_file /etc/udev/rules.d/70-muslman-nvidia.rules \
        "$(render_template "$tmpl/udev-rules.tmpl")"

    local ldpath
    ldpath="$(musl_ld_path_file)"
    append_line_once "$ldpath" "$MUSLMAN_PREFIX/nvidia/lib"

    local init
    init="$(detect_init_system)"
    case "$init" in
        systemd|unknown)
            ensure_dir /etc/modules-load.d
            install_managed_file /etc/modules-load.d/muslman-nvidia.conf \
                "$(render_template "$tmpl/modules-load.conf.tmpl")"
            ;;
        openrc)
            if [ -f /etc/modules-load.d/.exists ] || [ -d /etc/modules-load.d ]; then
                ensure_dir /etc/modules-load.d
                install_managed_file /etc/modules-load.d/muslman-nvidia.conf \
                    "$(render_template "$tmpl/modules-load.conf.tmpl")"
            elif [ -f /etc/conf.d/modules ]; then
                for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
                    append_line_once /etc/conf.d/modules "modules_add=\"$m\""
                done
                warn "appended module autoload lines to /etc/conf.d/modules -- double check its 'modules=' variable picks these up on your OpenRC setup"
            else
                warn "could not find /etc/modules-load.d or /etc/conf.d/modules -- add 'nvidia nvidia-modeset nvidia-drm nvidia-uvm' to your init system's module autoload list manually"
            fi
            ;;
        *)
            warn "unrecognized init system ('$init') -- add 'nvidia nvidia-modeset nvidia-drm nvidia-uvm' to your module autoload config manually"
            ;;
    esac
}

muslman_install() {
    require_root
    local libc
    libc="$(detect_libc)"
    if [ "$libc" != "musl" ]; then
        die "this system's libc was detected as '$libc', not musl. MuslMan installs a musl-compatible NVIDIA driver stack and refuses to run install/uninstall on a non-musl system as a safety guard. If this detection is wrong, check lib/distro.sh:detect_libc()."
    fi

    ensure_dir "$MUSLMAN_CACHE"
    manifest_init

    log "=== 1/6: resolving driver version ==="
    local ver runfile payload
    ver="$(driver_resolve_version)"
    log "using NVIDIA driver version $ver"
    runfile="$(driver_download "$ver")"

    log "=== 2/6: extracting driver payload ==="
    payload="$MUSLMAN_CACHE/payload-$ver"
    driver_extract "$runfile" "$payload"

    log "=== 3/6: building kernel modules (sandboxed, offline) ==="
    local ksrc kodir
    ksrc="$(driver_kernel_source_dir "$payload")"
    kodir="$MUSLMAN_CACHE/kmod-out-$ver"
    kmod_build "$ksrc" "$kodir"
    kmod_install "$kodir"

    log "=== 4/6: patching userspace libraries for glibc-compat (sandboxed, offline) ==="
    local glibc_extracted glibc_installed staging
    glibc_extracted="$(glibc_compat_fetch_and_extract)"
    glibc_installed="$(glibc_compat_install "$glibc_extracted")"
    staging="$MUSLMAN_CACHE/userspace-staging-$ver"
    rm -rf "$staging"
    userspace_collect "$payload" "$staging"
    userspace_patchelf "$staging" "$glibc_installed"
    userspace_install "$staging"

    log "=== 5/6: building Wayland/EGL/GBM integration (sandboxed, offline, native musl) ==="
    local egl_out
    egl_out="$(egl_integration_build)"
    egl_integration_install "$egl_out"

    log "=== 6/6: wiring system config (X11, EGL/Vulkan vendor files, udev, modprobe) ==="
    install_configs

    ok "MuslMan install complete."
    cat >&2 <<EOF

Next steps:
  1. Reboot (kernel modules + nouveau blacklist need a fresh boot), or
     manually: rmmod nouveau; modprobe nvidia nvidia-modeset nvidia-drm nvidia-uvm
  2. Check '$0 status' after reboot to confirm the modules loaded and
     /dev/nvidia* nodes exist.
  3. If your compositor/X session doesn't pick up acceleration, see the
     Troubleshooting section in README.md.

If anything looks wrong, 'sudo $0 uninstall' reverses everything MuslMan
touched (tracked in $MUSLMAN_MANIFEST, with .muslman-backup copies of any
file it overwrote).
EOF
}
