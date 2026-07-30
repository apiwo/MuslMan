# shellcheck shell=bash
# MuslMan driver.sh: resolve, fetch and extract the NVIDIA .run installer.
# Pure download/extract -- no compiling happens here.

NVIDIA_LATEST_TXT="https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt"

driver_resolve_version() {
    # Echoes the driver version to use, honoring --driver-version override.
    if [ -n "${MUSLMAN_DRIVER_VERSION:-}" ]; then
        echo "$MUSLMAN_DRIVER_VERSION"
        return 0
    fi
    require_cmd curl
    log "looking up latest NVIDIA production driver version..." >&2
    local line ver
    line="$(curl -fsSL "$NVIDIA_LATEST_TXT" 2>/dev/null)" || die "failed to fetch $NVIDIA_LATEST_TXT (pass --driver-version X.Y.Z to skip this lookup)"
    ver="$(echo "$line" | awk '{print $1}')"
    if ! echo "$ver" | grep -qE '^[0-9]+(\.[0-9]+){1,3}$'; then
        die "latest.txt did not look like a driver version ('$line') -- NVIDIA may have changed their layout. Pass --driver-version X.Y.Z explicitly."
    fi
    echo "$ver"
}

driver_run_filename() {
    echo "NVIDIA-Linux-x86_64-$1.run"
}

driver_download() {
    # driver_download <version>  -> prints path to the downloaded .run file
    local ver="$1" fname url dest
    if [ -n "${MUSLMAN_DRIVER_FILE:-}" ]; then
        [ -f "$MUSLMAN_DRIVER_FILE" ] || die "--driver-file '$MUSLMAN_DRIVER_FILE' does not exist"
        echo "$MUSLMAN_DRIVER_FILE"
        return 0
    fi
    fname="$(driver_run_filename "$ver")"
    url="https://download.nvidia.com/XFree86/Linux-x86_64/$ver/$fname"
    dest="$MUSLMAN_CACHE/$fname"
    ensure_dir "$MUSLMAN_CACHE"
    if [ ! -s "$dest" ]; then
        log "downloading $fname..." >&2
        curl -fL --retry 3 -o "$dest.part" "$url" || die "failed to download $url"
        mv "$dest.part" "$dest"
    fi
    # Sanity: a real .run is a shell-script-plus-payload makeself archive,
    # should start with a shebang and be several tens of MB.
    if ! head -c2 "$dest" | grep -q '#!'; then
        rm -f "$dest"
        die "downloaded file '$dest' doesn't look like an NVIDIA .run installer"
    fi
    if [ "$(stat -c%s "$dest" 2>/dev/null || echo 0)" -lt 20000000 ]; then
        warn "downloaded .run file is suspiciously small ($(stat -c%s "$dest" 2>/dev/null) bytes) -- continuing, but this may be an error page"
    fi
    echo "$dest"
}

driver_extract() {
    # driver_extract <run-file> <dest-dir>
    local runfile="$1" dest="$2"
    require_cmd sh
    rm -rf "$dest"
    ensure_dir "$dest"
    chmod +x "$runfile" 2>/dev/null || true
    log "extracting $(basename "$runfile")..." >&2
    sh "$runfile" --extract-only --target "$dest" >/dev/null || die "failed to extract $runfile (--extract-only)"
    ok "extracted NVIDIA payload to $dest" >&2
}

driver_kernel_source_dir() {
    # Prints the kernel module source dir to build: prefers kernel-open/.
    local payload="$1"
    if [ -d "$payload/kernel-open" ]; then
        echo "$payload/kernel-open"
    elif [ -d "$payload/kernel" ]; then
        echo "$payload/kernel"
    else
        die "no kernel/ or kernel-open/ directory found in extracted NVIDIA payload -- unexpected .run layout"
    fi
}
