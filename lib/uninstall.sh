# shellcheck shell=bash
# MuslMan uninstall.sh: reverses everything recorded in the manifest,
# restoring any .muslman-backup files it finds along the way.

muslman_uninstall() {
    require_root
    local libc
    libc="$(detect_libc)"
    if [ "$libc" != "musl" ]; then
        die "this system's libc was detected as '$libc', not musl. Refusing to run uninstall (there should be nothing for MuslMan to remove on a non-musl system)."
    fi

    if [ ! -f "$MUSLMAN_MANIFEST" ]; then
        warn "no manifest found at $MUSLMAN_MANIFEST -- nothing to uninstall (or install never completed)"
    else
        confirm "This will remove everything MuslMan installed (kernel modules, $MUSLMAN_PREFIX, and system config it wrote). Continue?" || die "aborted"

        log "unloading kernel modules..."
        for m in nvidia-uvm nvidia-drm nvidia-modeset nvidia; do
            modprobe -r "$m" 2>/dev/null || rmmod "$m" 2>/dev/null || true
        done

        log "reversing manifest entries..."
        # Process in reverse so line-appends and files are undone cleanly.
        tac "$MUSLMAN_MANIFEST" | while IFS=' ' read -r type rest; do
            case "$type" in
                line-append)
                    local path="${rest%%|*}" line="${rest#*|}"
                    [ -f "$path" ] && sed -i "\#^$(printf '%s' "$line" | sed 's/[.[\*^$/]/\\&/g')\$#d" "$path"
                    ;;
                file)
                    local path="$rest"
                    if [ -f "$path.muslman-backup" ]; then
                        mv "$path.muslman-backup" "$path"
                        log "restored $path from backup"
                    elif [ -f "$path" ]; then
                        rm -f "$path"
                    fi
                    ;;
                dir)
                    : # directories are removed in bulk below via $MUSLMAN_PREFIX
                    ;;
            esac
        done

        rm -f "$MUSLMAN_MANIFEST"
    fi

    if [ -d "$MUSLMAN_PREFIX" ]; then
        confirm "Remove $MUSLMAN_PREFIX entirely?" && rm -rf "$MUSLMAN_PREFIX"
    fi

    local kver moddir
    kver="$(uname -r)"
    moddir="/lib/modules/$kver/extra/muslman"
    if [ -d "$moddir" ]; then
        rm -rf "$moddir"
        depmod -a "$kver" || true
    fi

    ok "MuslMan uninstall complete. (Cached downloads in $MUSLMAN_CACHE were left alone; delete manually if you want to reclaim disk space.)"
}
