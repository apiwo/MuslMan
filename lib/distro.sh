# shellcheck shell=bash
# MuslMan distro detection: libc flavor + package manager.
# Deliberately generic (detect the package manager binary, not a distro
# name allowlist) so this works on any musl distro, not just the handful
# we've heard of.

detect_libc() {
    # Prints "musl", "glibc", or "unknown".
    #
    # Fast path: musl's dynamic linker is a uniquely-named file that glibc
    # systems never have.
    if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1 || ls /lib64/ld-musl-*.so.1 >/dev/null 2>&1; then
        echo musl
        return
    fi

    # Robust path: inspect what a real dynamically-linked binary actually
    # resolves against, rather than parsing `ldd --version` banner text --
    # that wording varies a lot by distro (e.g. Gentoo's patched ldd prints
    # "ldd (Gentoo 2.43-r2 ...)" with no "GNU"/"glibc" substring at all, so
    # matching banner text alone misdetects it as "unknown").
    if command -v ldd >/dev/null 2>&1; then
        local probe out
        probe="$(command -v sh || command -v ls || echo /bin/sh)"
        out="$(ldd "$probe" 2>/dev/null || true)"
        if echo "$out" | grep -q 'ld-musl'; then
            echo musl
            return
        fi
        if echo "$out" | grep -qE 'ld-linux|libc\.so\.6'; then
            echo glibc
            return
        fi
    fi

    echo unknown
}

musl_ld_path_file() {
    # The per-arch musl extra library search path file, e.g.
    # /etc/ld-musl-x86_64.path
    echo "/etc/ld-musl-${MUSLMAN_ARCH}.path"
}

detect_pkgmgr() {
    # Prints one of: apk xbps emerge pacman apt dnf zypper unknown
    if command -v apk >/dev/null 2>&1; then echo apk; return; fi
    if command -v xbps-install >/dev/null 2>&1; then echo xbps; return; fi
    if command -v emerge >/dev/null 2>&1; then echo emerge; return; fi
    if command -v pacman >/dev/null 2>&1; then echo pacman; return; fi
    if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
    if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
    if command -v zypper >/dev/null 2>&1; then echo zypper; return; fi
    echo unknown
}

# Suggested (never auto-run against the host) install command for a given
# logical package name, per package manager. Only used by `muslman doctor`
# to print guidance -- MuslMan never installs anything on the host itself,
# only inside its own sandbox rootfs.
pkgmgr_install_hint() {
    local mgr="$1" what="$2"
    case "$mgr" in
        apk)    echo "apk add $what" ;;
        xbps)   echo "xbps-install -S $what" ;;
        emerge) echo "emerge --ask $what" ;;
        pacman) echo "pacman -S $what" ;;
        apt)    echo "apt-get install $what" ;;
        dnf)    echo "dnf install $what" ;;
        zypper) echo "zypper install $what" ;;
        *)      echo "(unknown package manager -- install '$what' manually)" ;;
    esac
}

detect_init_system() {
    # Best-effort. Prints: systemd openrc runit s6 unknown
    if [ -d /run/systemd/system ]; then echo systemd; return; fi
    if command -v rc-service >/dev/null 2>&1 || [ -d /etc/init.d ] && [ -f /etc/inittab ] && command -v openrc >/dev/null 2>&1; then
        echo openrc; return
    fi
    if command -v rc-status >/dev/null 2>&1; then echo openrc; return; fi
    if [ -d /etc/runit ]; then echo runit; return; fi
    if command -v s6-rc >/dev/null 2>&1; then echo s6; return; fi
    echo unknown
}

kernel_build_dir() {
    # Where this kernel's headers/build tree should live, if present.
    local kver
    kver="$(uname -r)"
    if [ -e "/lib/modules/$kver/build" ]; then
        # resolve symlink to a real path for bind-mounting
        readlink -f "/lib/modules/$kver/build"
        return 0
    fi
    if [ -d "/usr/src/linux" ]; then
        readlink -f "/usr/src/linux"
        return 0
    fi
    return 1
}
