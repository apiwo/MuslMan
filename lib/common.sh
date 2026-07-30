# shellcheck shell=bash
# MuslMan common helpers: logging, root checks, arch/paths.
# Sourced by every other lib/*.sh and by ./muslman itself.

set -uo pipefail

MUSLMAN_VERSION="0.1.0"

# --- paths -------------------------------------------------------------
MUSLMAN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUSLMAN_PREFIX="${MUSLMAN_PREFIX:-/opt/muslman}"
MUSLMAN_STATE_DIR="${MUSLMAN_STATE_DIR:-/var/lib/muslman}"
MUSLMAN_MANIFEST="$MUSLMAN_STATE_DIR/manifest"
MUSLMAN_CACHE="${MUSLMAN_CACHE:-$HOME/.cache/muslman}"

# --- colors / logging ---------------------------------------------------
if [ -t 2 ]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_BLU=""; C_RST=""
fi

log()  { printf '%s[muslman]%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
ok()   { printf '%s[  ok  ]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s[ warn ]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[ err  ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "this command must be run as root (try: sudo $0 $*)"
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}

confirm() {
    # confirm "message" -- returns 0 (yes) or 1 (no). Auto-yes if MUSLMAN_YES=1.
    local msg="$1"
    if [ "${MUSLMAN_YES:-0}" = "1" ]; then
        return 0
    fi
    printf '%s [y/N] ' "$msg" >&2
    read -r reply || return 1
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64) echo "x86_64" ;;
        *) echo "$m" ;;
    esac
}

MUSLMAN_ARCH="$(detect_arch)"

ensure_dir() {
    mkdir -p "$1"
}

# manifest helpers: track every file we create/overwrite so uninstall can
# reverse it cleanly. One line per entry: "<type> <path>"
manifest_init() {
    ensure_dir "$MUSLMAN_STATE_DIR"
    touch "$MUSLMAN_MANIFEST"
}

manifest_add() {
    # manifest_add <type> <path>   type: file|dir|module|line-append
    manifest_init
    echo "$1 $2" >> "$MUSLMAN_MANIFEST"
}

# Write $2 to path $1, backing up any pre-existing file to <path>.muslman-backup
# (only the first time — never clobber an older backup), and record it in the manifest.
install_managed_file() {
    local path="$1" content="$2" mode="${3:-0644}"
    ensure_dir "$(dirname "$path")"
    if [ -e "$path" ] && [ ! -e "$path.muslman-backup" ]; then
        cp -a "$path" "$path.muslman-backup"
        log "backed up existing $path -> $path.muslman-backup"
    fi
    printf '%s' "$content" > "$path"
    chmod "$mode" "$path"
    manifest_add file "$path"
    ok "wrote $path"
}

# Idempotently append a line to a file if not already present, recording it
# so uninstall can remove exactly that line (not the whole file).
append_line_once() {
    local path="$1" line="$2"
    ensure_dir "$(dirname "$path")"
    touch "$path"
    if ! grep -qxF "$line" "$path" 2>/dev/null; then
        if [ ! -e "$path.muslman-backup" ]; then
            cp -a "$path" "$path.muslman-backup"
        fi
        echo "$line" >> "$path"
        manifest_add line-append "$path|$line"
        ok "appended to $path: $line"
    fi
}
