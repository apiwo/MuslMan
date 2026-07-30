# shellcheck shell=bash
# MuslMan doctor.sh: check host prerequisites and PRINT (never run) the
# fix for anything missing. MuslMan never installs packages on the host --
# only inside its own sandbox rootfs -- so this is advisory only.

muslman_doctor() {
    local libc pkgmgr problems=0
    libc="$(detect_libc)"
    pkgmgr="$(detect_pkgmgr)"

    echo "MuslMan doctor"
    echo "--------------"

    if [ "$libc" = "musl" ]; then
        ok "libc: musl"
    else
        err "libc: $libc (MuslMan targets musl systems only -- refusing to run install here)"
        problems=$((problems+1))
    fi

    if [ "$MUSLMAN_ARCH" = "x86_64" ]; then
        ok "arch: x86_64"
    else
        err "arch: $MUSLMAN_ARCH (unsupported -- NVIDIA doesn't ship consumer Linux drivers for this architecture)"
        problems=$((problems+1))
    fi

    echo "package manager detected: $pkgmgr"

    if command -v bwrap >/dev/null 2>&1; then
        ok "bwrap (bubblewrap): $(bwrap --version 2>&1)"
    else
        err "bwrap (bubblewrap) not found"
        echo "    fix: $(pkgmgr_install_hint "$pkgmgr" bubblewrap)"
        problems=$((problems+1))
    fi

    for c in curl tar depmod modprobe lsmod; do
        if command -v "$c" >/dev/null 2>&1; then
            ok "$c found"
        else
            err "$c not found"
            echo "    fix: $(pkgmgr_install_hint "$pkgmgr" "$c (check which package provides it on your distro)")"
            problems=$((problems+1))
        fi
    done

    if kdir="$(kernel_build_dir)"; then
        ok "kernel build tree: $kdir"
    else
        err "no kernel build/headers tree found for running kernel ($(uname -r))"
        case "$pkgmgr" in
            apk)    echo "    fix: apk add linux-\$(uname -r | grep -oE 'lts|virt|edge' || echo lts)-dev" ;;
            xbps)   echo "    fix: xbps-install -S linux-headers" ;;
            emerge) echo "    fix: emerge --ask sys-kernel/gentoo-sources   # then configure+build it to match your running kernel" ;;
            *)      echo "    fix: install your distro's kernel headers/build package for $(uname -r)" ;;
        esac
        problems=$((problems+1))
    fi

    if lspci_out="$(command -v lspci 2>/dev/null)"; then
        ok "lspci found ($lspci_out)"
        if command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi nvidia; then
            ok "NVIDIA GPU detected:"
            lspci 2>/dev/null | grep -i nvidia | sed 's/^/    /'
        else
            warn "lspci ran but found no NVIDIA device -- is this the right machine?"
        fi
    else
        warn "lspci not found -- can't verify an NVIDIA GPU is present"
        echo "    fix: $(pkgmgr_install_hint "$pkgmgr" pciutils)"
    fi

    echo
    if [ "$problems" -eq 0 ]; then
        ok "all checks passed -- ready for 'sudo ./muslman install'"
    else
        err "$problems problem(s) found -- fix the above, then re-run 'muslman doctor'"
    fi
    return "$problems"
}
