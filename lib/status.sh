# shellcheck shell=bash
# MuslMan status.sh: report on the current state of a MuslMan install.

muslman_status() {
    echo "MuslMan v$MUSLMAN_VERSION"
    echo "libc:          $(detect_libc)"
    echo "arch:          $MUSLMAN_ARCH"
    echo "pkg manager:   $(detect_pkgmgr)"
    echo "init system:   $(detect_init_system)"
    echo "kernel:        $(uname -r)"
    echo

    if [ -d "$MUSLMAN_PREFIX/nvidia" ]; then
        ok "install prefix present: $MUSLMAN_PREFIX/nvidia"
    else
        warn "install prefix not found: $MUSLMAN_PREFIX/nvidia (not installed?)"
    fi

    echo
    echo "kernel modules loaded:"
    for m in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
        if lsmod 2>/dev/null | grep -q "^$m "; then
            ok "  $m"
        else
            warn "  $m: not loaded"
        fi
    done

    echo
    echo "device nodes:"
    for d in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm; do
        if [ -e "$d" ]; then
            ok "  $d"
        else
            warn "  $d: missing"
        fi
    done

    echo
    if [ -x "$MUSLMAN_PREFIX/nvidia/bin/nvidia-smi" ]; then
        echo "nvidia-smi output:"
        "$MUSLMAN_PREFIX/nvidia/bin/nvidia-smi" 2>&1 | sed 's/^/  /' || warn "nvidia-smi failed to run"
    fi

    if [ -f "$MUSLMAN_MANIFEST" ]; then
        echo
        echo "manifest: $MUSLMAN_MANIFEST ($(wc -l < "$MUSLMAN_MANIFEST") entries)"
    fi
}
