#!/usr/bin/env bash
# =============================================================================
# StreamCache installer
# Installs the shell frontend and/or the Python package.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHELL_SOURCE="${SCRIPT_DIR}/streamcache"
DEFAULT_BIN_DIR="${HOME}/bin"
VERSION="0.12.0"

MODE="all"          # all | shell | python
BIN_DIR="${DEFAULT_BIN_DIR}"
PYTHON_METHOD="pipx" # pipx | pip | editable
SKIP_DEPS=0
FORCE=0

usage() {
    cat <<'EOF'
Usage: scripts/install.sh [options]

Install StreamCache on this machine.

Options:
  --mode MODE         all (default), shell, or python
  --bin-dir DIR       Install shell script here (default: ~/bin)
  --python METHOD     pipx (default), pip, or editable
  --skip-deps         Do not check/install ffmpeg or yt-dlp hints
  --force             Overwrite existing shell install without prompt
  -h, --help          Show this help

Examples:
  ./scripts/install.sh
  ./scripts/install.sh --mode shell
  ./scripts/install.sh --mode python --python editable
  ./scripts/install.sh --bin-dir ~/.local/bin --mode shell
EOF
}

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                [[ $# -ge 2 ]] || die "--mode requires a value"
                MODE="$2"
                shift 2
                ;;
            --bin-dir)
                [[ $# -ge 2 ]] || die "--bin-dir requires a value"
                BIN_DIR="$2"
                shift 2
                ;;
            --python)
                [[ $# -ge 2 ]] || die "--python requires a value"
                PYTHON_METHOD="$2"
                shift 2
                ;;
            --skip-deps)
                SKIP_DEPS=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    case "$MODE" in
        all|shell|python) ;;
        *) die "Invalid --mode: $MODE (use all, shell, or python)" ;;
    esac
    case "$PYTHON_METHOD" in
        pipx|pip|editable) ;;
        *) die "Invalid --python: $PYTHON_METHOD (use pipx, pip, or editable)" ;;
    esac
}

check_deps() {
    (( SKIP_DEPS )) && return 0
    say "Checking dependencies"
    if ! command -v ffmpeg >/dev/null 2>&1; then
        warn "ffmpeg is not installed (required for merge/remux/MP3/metadata)."
        if command -v zypper >/dev/null 2>&1; then
            printf 'Install with: sudo zypper install ffmpeg\n'
        else
            printf 'Install ffmpeg with your package manager.\n'
        fi
    else
        printf 'ffmpeg: %s\n' "$(command -v ffmpeg)"
    fi
    if ! command -v yt-dlp >/dev/null 2>&1; then
        warn "yt-dlp is not on PATH. The Python install pulls it in as a dependency."
        if command -v zypper >/dev/null 2>&1; then
            printf 'Optional system install: sudo zypper install yt-dlp\n'
        fi
    else
        printf 'yt-dlp: %s (%s)\n' "$(command -v yt-dlp)" "$(yt-dlp --version 2>/dev/null || echo unknown)"
    fi
}

install_shell() {
    say "Installing shell StreamCache ${VERSION}"
    [[ -f "$SHELL_SOURCE" ]] || die "Missing shell script: $SHELL_SOURCE"
    need_cmd install
    mkdir -p "$BIN_DIR" || die "Could not create bin dir: $BIN_DIR"
    local target="${BIN_DIR%/}/streamcache"

    if [[ -e "$target" && "$FORCE" -ne 1 ]]; then
        if [[ -L "$target" ]]; then
            warn "Existing symlink at $target -> $(readlink -f "$target" 2>/dev/null || readlink "$target")"
        else
            warn "Existing file at $target"
        fi
        # Back up non-identical files
        if ! cmp -s "$SHELL_SOURCE" "$target" 2>/dev/null; then
            local bak="${target}.bak-$(date '+%Y%m%d-%H%M%S')"
            cp -a "$target" "$bak"
            printf 'Backed up previous install to %s\n' "$bak"
        fi
    fi

    install -m 0755 "$SHELL_SOURCE" "$target" || die "Failed to install shell script to $target"
    printf 'Installed: %s\n' "$target"

    # Ensure VERSION string matches package release
    if grep -q 'VERSION=' "$target"; then
        sed -i "s/^VERSION=.*/VERSION=\"${VERSION}\"/" "$target"
        sed -i "s/^# StreamCache v.*/# StreamCache v${VERSION}/" "$target"
    fi

    if ! command -v streamcache >/dev/null 2>&1; then
        warn "$BIN_DIR may not be on PATH. Add it, e.g.:"
        printf '  fish: fish_add_path %s\n' "$BIN_DIR"
        printf '  bash: export PATH=\"%s:\$PATH\"\n' "$BIN_DIR"
    fi

    # Report which streamcache will run first on PATH
    if command -v streamcache >/dev/null 2>&1; then
        printf 'PATH resolves streamcache -> %s\n' "$(command -v streamcache)"
    fi
}

install_python() {
    say "Installing Python StreamCache ${VERSION} (${PYTHON_METHOD})"
    need_cmd python3
    [[ -f "${REPO_ROOT}/pyproject.toml" ]] || die "pyproject.toml not found in ${REPO_ROOT}"

    case "$PYTHON_METHOD" in
        pipx)
            if ! command -v pipx >/dev/null 2>&1; then
                die "pipx not found. Install pipx or use --python pip / --python editable"
            fi
            # Uninstall first: pipx --force can fail under uv-backed venvs.
            if pipx list 2>/dev/null | grep -qi 'package streamcache'; then
                pipx uninstall streamcache || warn "Could not uninstall previous pipx streamcache"
            fi
            pipx install "${REPO_ROOT}" || die "pipx install failed"
            ;;
        pip)
            python3 -m pip install --user --upgrade "${REPO_ROOT}" || die "pip install failed"
            ;;
        editable)
            python3 -m pip install --user --upgrade -e "${REPO_ROOT}" || die "editable pip install failed"
            ;;
    esac

    if command -v streamcache >/dev/null 2>&1; then
        printf 'streamcache --version -> '
        streamcache --version || true
    else
        warn "streamcache entry point not found on PATH after Python install."
    fi
}

main() {
    parse_args "$@"
    say "StreamCache installer v${VERSION}"
    printf 'Repo:   %s\n' "$REPO_ROOT"
    printf 'Mode:   %s\n' "$MODE"
    printf 'Bin:    %s\n' "$BIN_DIR"
    printf 'Python: %s\n' "$PYTHON_METHOD"

    check_deps

    case "$MODE" in
        all)
            install_shell
            install_python
            ;;
        shell)
            install_shell
            ;;
        python)
            install_python
            ;;
    esac

    say "Done"
    printf 'Shell script source: %s\n' "$SHELL_SOURCE"
    printf 'Installed shell target: %s/streamcache\n' "${BIN_DIR%/}"
    if command -v streamcache >/dev/null 2>&1; then
        printf 'Active command: %s\n' "$(command -v -a streamcache 2>/dev/null | tr '\n' ' ')"
    fi
}

main "$@"
