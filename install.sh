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
INSTALL_DESKTOP=1
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="${DESKTOP_DIR}/streamcache.desktop"

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
  --no-desktop        Do not add a Start Menu / app launcher entry
  --desktop-only      Only install/update the Start Menu entry
  --remove-desktop    Remove the Start Menu entry and exit
  -h, --help          Show this help

Examples:
  ./scripts/install.sh
  ./scripts/install.sh --mode shell
  ./scripts/install.sh --mode python --python editable
  ./scripts/install.sh --bin-dir ~/.local/bin --mode shell
  ./scripts/install.sh --desktop-only
  ./scripts/install.sh --remove-desktop
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
            --no-desktop)
                INSTALL_DESKTOP=0
                shift
                ;;
            --desktop-only)
                MODE="desktop"
                shift
                ;;
            --remove-desktop)
                MODE="remove-desktop"
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
        all|shell|python|desktop|remove-desktop) ;;
        *) die "Invalid --mode: $MODE (use all, shell, python, desktop, or remove-desktop)" ;;
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

resolve_streamcache_exec() {
    # Prefer an installed shell script, then PATH lookup.
    local candidate="${BIN_DIR%/}/streamcache"
    if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    if command -v streamcache >/dev/null 2>&1; then
        command -v streamcache
        return 0
    fi
    if [[ -x "$SHELL_SOURCE" ]]; then
        printf '%s\n' "$SHELL_SOURCE"
        return 0
    fi
    return 1
}

install_desktop_entry() {
    say "Installing Start Menu launcher"
    local exec_path terminal_emu
    exec_path="$(resolve_streamcache_exec)" || die \
        "No streamcache executable found. Install the shell or Python app first, or pass --bin-dir."

    mkdir -p "$DESKTOP_DIR" || die "Could not create $DESKTOP_DIR"

    # Prefer a terminal that can run a command then keep the session open for UI work.
    # StreamCache is interactive, so the .desktop entry must launch inside a terminal.
    terminal_emu=""
    if command -v konsole >/dev/null 2>&1; then
        # KDE / openSUSE default path
        cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.5
Name=StreamCache
GenericName=Media Archiver
Comment=Interactive multi-source media archiver (yt-dlp) v${VERSION}
Exec=konsole -e "$exec_path"
Icon=folder-videos
Terminal=false
Categories=AudioVideo;Network;Utility;
Keywords=download;archive;yt-dlp;video;audio;playlist;
StartupNotify=true
EOF
    else
        # Portable FreeDesktop style: let the desktop environment open a terminal.
        cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.5
Name=StreamCache
GenericName=Media Archiver
Comment=Interactive multi-source media archiver (yt-dlp) v${VERSION}
Exec="$exec_path"
Icon=folder-videos
Terminal=true
Categories=AudioVideo;Network;Utility;
Keywords=download;archive;yt-dlp;video;audio;playlist;
StartupNotify=true
EOF
    fi

    chmod 0644 "$DESKTOP_FILE" || true
    printf 'Desktop entry: %s\n' "$DESKTOP_FILE"
    printf 'Launches:      %s\n' "$exec_path"

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
    fi
    if command -v xdg-desktop-menu >/dev/null 2>&1; then
        xdg-desktop-menu forceupdate >/dev/null 2>&1 || true
    fi

    printf 'StreamCache should appear in your application / start menu shortly.\n'
    printf 'If it does not, log out/in or run: update-desktop-database %s\n' "$DESKTOP_DIR"
}

remove_desktop_entry() {
    say "Removing Start Menu launcher"
    if [[ -f "$DESKTOP_FILE" ]]; then
        rm -f "$DESKTOP_FILE"
        printf 'Removed: %s\n' "$DESKTOP_FILE"
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
        fi
        if command -v xdg-desktop-menu >/dev/null 2>&1; then
            xdg-desktop-menu forceupdate >/dev/null 2>&1 || true
        fi
    else
        printf 'No desktop entry found at %s\n' "$DESKTOP_FILE"
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
    printf 'Menu:   %s\n' "$([[ "$INSTALL_DESKTOP" -eq 1 ]] && echo yes || echo no)"

    case "$MODE" in
        remove-desktop)
            remove_desktop_entry
            say "Done"
            return 0
            ;;
        desktop)
            install_desktop_entry
            say "Done"
            return 0
            ;;
    esac

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

    if (( INSTALL_DESKTOP )); then
        install_desktop_entry || warn "Start Menu entry was not installed."
    fi

    say "Done"
    printf 'Shell script source: %s\n' "$SHELL_SOURCE"
    printf 'Installed shell target: %s/streamcache\n' "${BIN_DIR%/}"
    if [[ -f "$DESKTOP_FILE" ]]; then
        printf 'Start menu entry: %s\n' "$DESKTOP_FILE"
    fi
    if command -v streamcache >/dev/null 2>&1; then
        printf 'Active command: %s\n' "$(command -v -a streamcache 2>/dev/null | tr '\n' ' ')"
    fi
}

main "$@"
