# shellcheck shell=bash
# MuslMan sandbox: all compiling happens in here, never on the bare host.
#
# Backend is bubblewrap (bwrap) against a cached Alpine musl minirootfs.
# We use Alpine's rootfs as the *build* environment regardless of what
# distro MuslMan is being installed onto: musl has no symbol versioning,
# so small userspace libraries (egl-wayland, egl-gbm) built against one
# musl version run fine against another. Kernel modules only need to
# match the *kernel* ABI (via bind-mounted host kernel headers), not the
# libc used to run gcc. Advanced users can override with
# MUSLMAN_ROOTFS_TARBALL=/path/to/their-own-rootfs.tar.gz if they want to
# build against their exact target distro instead.

ALPINE_VERSION="${MUSLMAN_ALPINE_VERSION:-3.20.3}"
ALPINE_BRANCH="${ALPINE_VERSION%.*}" # e.g. 3.20

SANDBOX_ROOTFS="$MUSLMAN_CACHE/sandbox-rootfs"
SANDBOX_STAMP_BOOTSTRAP="$MUSLMAN_CACHE/.sandbox-bootstrapped"
SANDBOX_STAMP_BUILDDEPS="$MUSLMAN_CACHE/.sandbox-builddeps-installed"

require_bwrap() {
    command -v bwrap >/dev/null 2>&1 || die "bubblewrap (bwrap) is required but not found on PATH. Install it with your package manager (e.g. 'apk add bubblewrap', 'xbps-install bubblewrap', 'emerge sys-apps/bubblewrap')."
}

sandbox_arch_alpine() {
    case "$MUSLMAN_ARCH" in
        x86_64) echo x86_64 ;;
        *) die "unsupported architecture '$MUSLMAN_ARCH' -- MuslMan currently only supports x86_64 (NVIDIA does not ship consumer GeForce/RTX Linux drivers for other architectures)" ;;
    esac
}

sandbox_bootstrap() {
    # Downloads + extracts the Alpine minirootfs once. Idempotent.
    require_bwrap
    require_cmd curl
    require_cmd tar

    if [ -n "${MUSLMAN_ROOTFS_TARBALL:-}" ]; then
        if [ -f "$SANDBOX_STAMP_BOOTSTRAP" ] && [ "$(cat "$SANDBOX_STAMP_BOOTSTRAP" 2>/dev/null)" = "custom:$MUSLMAN_ROOTFS_TARBALL" ]; then
            return 0
        fi
        log "bootstrapping sandbox rootfs from user-supplied tarball: $MUSLMAN_ROOTFS_TARBALL"
        rm -rf "$SANDBOX_ROOTFS"
        ensure_dir "$SANDBOX_ROOTFS"
        tar -xf "$MUSLMAN_ROOTFS_TARBALL" -C "$SANDBOX_ROOTFS"
        echo "custom:$MUSLMAN_ROOTFS_TARBALL" > "$SANDBOX_STAMP_BOOTSTRAP"
        rm -f "$SANDBOX_STAMP_BUILDDEPS"
        ok "sandbox rootfs ready (custom tarball) at $SANDBOX_ROOTFS"
        return 0
    fi

    if [ -f "$SANDBOX_STAMP_BOOTSTRAP" ] && [ "$(cat "$SANDBOX_STAMP_BOOTSTRAP" 2>/dev/null)" = "alpine:$ALPINE_VERSION" ] && [ -d "$SANDBOX_ROOTFS/bin" ]; then
        return 0
    fi

    local a tarball url dest
    a="$(sandbox_arch_alpine)"
    tarball="alpine-minirootfs-${ALPINE_VERSION}-${a}.tar.gz"
    url="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_BRANCH}/releases/${a}/${tarball}"
    dest="$MUSLMAN_CACHE/$tarball"

    ensure_dir "$MUSLMAN_CACHE"
    if [ ! -s "$dest" ]; then
        log "downloading Alpine musl minirootfs $ALPINE_VERSION ($a) for the build sandbox..."
        curl -fL --retry 3 -o "$dest.part" "$url" || die "failed to download $url"
        mv "$dest.part" "$dest"
    fi

    # Sanity check: must be a real gzip tarball of non-trivial size, not an
    # HTML error page saved by a redirect.
    if [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" -lt 1000000 ]; then
        rm -f "$dest"
        die "downloaded rootfs tarball looks too small / corrupt: $url"
    fi
    if ! (gzip -t "$dest" 2>/dev/null || xz -t "$dest" 2>/dev/null); then
        die "downloaded rootfs tarball failed integrity check: $dest"
    fi

    log "extracting sandbox rootfs..."
    rm -rf "$SANDBOX_ROOTFS"
    ensure_dir "$SANDBOX_ROOTFS"
    tar -xzf "$dest" -C "$SANDBOX_ROOTFS"

    # A few bind targets bwrap needs to exist inside the rootfs.
    ensure_dir "$SANDBOX_ROOTFS/proc"
    ensure_dir "$SANDBOX_ROOTFS/dev"
    ensure_dir "$SANDBOX_ROOTFS/tmp"
    ensure_dir "$SANDBOX_ROOTFS/work"
    ensure_dir "$SANDBOX_ROOTFS/etc"
    cp -a /etc/resolv.conf "$SANDBOX_ROOTFS/etc/resolv.conf" 2>/dev/null || true

    echo "alpine:$ALPINE_VERSION" > "$SANDBOX_STAMP_BOOTSTRAP"
    rm -f "$SANDBOX_STAMP_BUILDDEPS"
    ok "sandbox rootfs ready at $SANDBOX_ROOTFS"
}

# Run a command inside the sandbox WITH network access. Only used for the
# one-time build-dependency install step. Never used for compiling.
sandbox_exec_net() {
    require_bwrap
    bwrap \
        --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup \
        --die-with-parent \
        --bind "$SANDBOX_ROOTFS" / \
        --proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --chdir /work \
        --setenv HOME /root \
        --setenv PATH /usr/sbin:/usr/bin:/sbin:/bin \
        -- /bin/sh -c "$*"
}

# sandbox_run_offline <workdir-on-host> <shell-command> [--bind host:container]...
# The hard isolation boundary used for every actual compile/link/patch
# step: --unshare-net means the sandbox has no network access at all
# while a compiler or patchelf is running.
sandbox_run_offline() {
    local workdir="$1"; shift
    local cmd="$1"; shift
    local bwrap_args=(
        --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup --unshare-net
        --die-with-parent
        --bind "$SANDBOX_ROOTFS" /
        --proc /proc
        --dev /dev
        --tmpfs /tmp
        --bind "$workdir" /work
        --chdir /work
        --setenv HOME /root
        --setenv PATH /usr/sbin:/usr/bin:/sbin:/bin
    )
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --ro-bind)
                bwrap_args+=(--ro-bind "$2" "$3"); shift 3 ;;
            --bind)
                bwrap_args+=(--bind "$2" "$3"); shift 3 ;;
            *)
                die "sandbox_run_offline: unknown arg $1" ;;
        esac
    done
    bwrap "${bwrap_args[@]}" -- /bin/sh -c "$cmd"
}

sandbox_ensure_builddeps() {
    sandbox_bootstrap
    if [ -f "$SANDBOX_STAMP_BUILDDEPS" ]; then
        return 0
    fi
    log "installing build dependencies into sandbox rootfs (one-time, network enabled for this step only)..."
    ensure_dir "$SANDBOX_ROOTFS/work"
    sandbox_exec_net "apk update && apk add --no-cache \
        gcc make musl-dev linux-headers patchelf meson ninja pkgconf \
        wayland-dev wayland-protocols libdrm-dev mesa-dev eudev-dev \
        tar xz curl git perl" \
        || die "failed to install sandbox build dependencies"
    touch "$SANDBOX_STAMP_BUILDDEPS"
    ok "sandbox build dependencies installed"
}
