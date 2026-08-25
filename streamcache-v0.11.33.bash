#!/usr/bin/env bash
# =============================================================================
# StreamCache v0.11.33
# Interactive YouTube / YouTube Music media archiver powered by yt-dlp.
# =============================================================================
set -Eeuo pipefail

VERSION="0.11.33"
CLEAR_SCREEN=1
DEFAULT_OUTPUT_DIR="$HOME/Videos/streamcache"

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    RESET=$'\e[0m'; BOLD=$'\e[1m'; DIM=$'\e[2m'
    CYAN=$'\e[1;36m'; BLUE=$'\e[1;34m'; GREEN=$'\e[1;32m'
    YELLOW=$'\e[1;33m'; MAGENTA=$'\e[1;35m'; RED=$'\e[1;31m'; GRAY=$'\e[0;90m'
else
    RESET='' BOLD='' DIM='' CYAN='' BLUE='' GREEN='' YELLOW='' MAGENTA='' RED='' GRAY=''
fi

say() { printf '\n%s%s==>%s %s\n' "$BLUE" "$BOLD" "$RESET" "$*"; }
warn() { printf '\n%s%sWARNING:%s %s\n' "$YELLOW" "$BOLD" "$RESET" "$*" >&2; }
die() { printf '\n%s%sERROR:%s %s\n' "$RED" "$BOLD" "$RESET" "$*" >&2; exit 1; }

center_box_line() {
    local plain="$1"
    local rendered="$2"
    local width=76
    local left=$(( (width - ${#plain}) / 2 ))
    local right=$(( width - left - ${#plain} ))

    if (( left < 0 )); then
        left=0
    fi
    if (( right < 0 )); then
        right=0
    fi

    printf '%s|%s%*s%s%*s%s|%s
' \
        "$CYAN" "$RESET" \
        "$left" '' \
        "$rendered" \
        "$right" '' \
        "$CYAN" "$RESET"
}

show_banner() {
    if (( CLEAR_SCREEN )); then
        clear
    fi
    printf '%s%s' "$CYAN" "$BOLD"
    cat <<'EOF'
+----------------------------------------------------------------------------+
|                                                                            |
|     _____ _                                    ____           _            |
|    / ____| |                                  / ___|__ _  ___| |__   ___   |
|    \___ \| |_ _ __ ___  __ _ _ __ ___        | |   / _` |/ __| '_ \ / _ \  |
|    ____) | __| '__/ _ \/ _` | '_ ` _ \       | |__| (_| | (__| | | |  __/  |
|   |_____/ \__|_|  \___/\__,_|_| |_| |_|       \____\__,_|\___|_| |_|\___|  |
|                                                                            |
|                 Y T - D L P   M E D I A   A R C H I V E R                  |
|                                                                            |
+----------------------------------------------------------------------------+
EOF
    printf '%s' "$RESET"
    center_box_line \
        'BEST QUALITY | METADATA | SAFE RESUME' \
        "${GREEN}BEST QUALITY${RESET} | ${YELLOW}METADATA${RESET} | ${CYAN}SAFE RESUME${RESET}"
    printf '%s%s%s
' "$CYAN" "+----------------------------------------------------------------------------+" "$RESET"
    cat <<'EOF'

StreamCache is an interactive YouTube and YouTube Music media archiver.

VIDEO - Best-quality MKV, compatibility-first MP4, or manual resolution
selection.

AUDIO - High-quality V0 MP3 with embedded metadata and cover art.

RESUME - Resumable playlist downloads, an ID-based download archive,
organized output folders, and timestamped run logs.

EXTRAS - Optional subtitles, archival sidecars, and browser-cookie support.

EOF
    printf '%s%s%s
' "$CYAN" "+----------------------------------------------------------------------------+" "$RESET"
    center_box_line \
        'Supports YouTube and YouTube Music URLs. Additional sources may follow.' \
        'Supports YouTube and YouTube Music URLs. Additional sources may follow.'
    printf '%s%s%s
' "$CYAN" "+----------------------------------------------------------------------------+" "$RESET"
    printf '
%s v%s%s

' "$DIM" "$VERSION" "$RESET"
}

set_output_dir() {
    local requested
    say "Archive root"
    printf '%sSave root%s [%s]: ' "$YELLOW" "$RESET" "$output_dir"
    read -r requested
    requested="${requested:-$output_dir}"
    mkdir -p "$requested" || die "Could not create $requested"
    output_dir="$(cd "$requested" && pwd -P)"
    mkdir -p "$output_dir/playlists" "$output_dir/singles" "$output_dir/logs" \
        "$output_dir/archive" "$output_dir/.streamcache-tmp" || die "Could not create StreamCache folders."
}

update_yt_dlp() {
    local path owner choice
    path="$(command -v yt-dlp)"
    owner="$(rpm -qf "$path" 2>/dev/null || true)"
    if [[ -n "$owner" && "$owner" != *"is not owned by any package"* ]]; then
        say "yt-dlp is managed by RPM"
        printf 'Executable: %s\nPackage: %s\nVersion: ' "$path" "$owner"
        yt-dlp --version
        printf '%sCheck openSUSE repositories for a yt-dlp update now?%s [y/N]: ' "$YELLOW" "$RESET"
        read -r choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            command -v sudo >/dev/null 2>&1 || die "sudo is required for a zypper update."
            sudo zypper refresh && sudo zypper update -y yt-dlp || warn "Update failed; continuing with installed yt-dlp."
        fi
    else
        say "Checking yt-dlp's upstream update channel"
        yt-dlp -U || warn "yt-dlp could not self-update. Update it through the tool that installed it."
    fi
}

inspect_source() {
    say "Inspecting source (no media will be downloaded)"
    yt-dlp --flat-playlist --ignore-errors \
        --print 'Collection: %(playlist_title)s' \
        --print 'Channel: %(playlist_uploader)s' \
        --print 'Items: %(playlist_count)s' \
        --print '%(playlist_index)02d. %(title)s [%(id)s] (%(duration_string)s)' \
        "$url" || warn "Inspection reported an issue; the URL may still work."
}

choose_download_mode() {
    say "Download mode"
    printf '1) Best available video + audio (MKV enforced, recommended)\n'
    printf '2) Best video + audio compatible with MP4 when possible\n'
    printf '3) Audio only (best source audio -> high-quality MP3 with cover art)\n'
    printf '4) List formats and choose a resolution or exact format IDs (MKV enforced)\n'
    printf '%sChoose%s [1]: ' "$YELLOW" "$RESET"
    read -r mode
    mode="${mode:-1}"
    format_args=() container_args=() format_description='' container_policy=''
    case "$mode" in
        1)
            format_args=(-f 'bv*+ba/b')
            container_args=(--merge-output-format mkv --remux-video mkv)
            format_description='best available video + audio'
            container_policy='MKV enforced'
            ;;
        2)
            format_args=(-f 'bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b')
            container_args=(--merge-output-format mp4)
            format_description='best MP4-compatible video + audio'
            container_policy='MP4 preferred where possible'
            ;;
        3)
            format_args=(-f 'ba/b' -x --audio-format mp3 --audio-quality 0)
            format_description='best source audio -> high-quality MP3 (V0 VBR) with embedded cover art'
            container_policy='audio-only'
            ;;
        4)
            say "Available formats"
            printf '%sRepresentative track/video URL%s [current URL]: ' "$YELLOW" "$RESET"
            read -r inspect_url
            inspect_url="${inspect_url:-$url}"
            yt-dlp -F "$inspect_url" || die "Could not list formats."
            printf '1) Best quality up to a resolution\n2) Exact format ID(s)\n'
            printf '%sChoose%s [1]: ' "$YELLOW" "$RESET"
            read -r method
            case "${method:-1}" in
                1)
                    printf '%sMaximum height%s [1080]: ' "$YELLOW" "$RESET"
                    read -r height
                    height="${height:-1080}"
                    [[ "$height" =~ ^[0-9]+$ ]] || die "Height must be a number."
                    format_args=(-f "bv*[height<=?${height}]+ba/b[height<=?${height}]")
                    format_description="best video up to ${height}p + best audio"
                    ;;
                2)
                    printf '%sFormat ID(s)%s, e.g. 248+251: ' "$YELLOW" "$RESET"
                    read -r exact_format
                    [[ -n "$exact_format" ]] || die "No format ID supplied."
                    format_args=(-f "$exact_format")
                    format_description="manually selected format: ${exact_format}"
                    ;;
                *)
                    die "Invalid manual selection."
                    ;;
            esac
            container_args=(--merge-output-format mkv --remux-video mkv)
            container_policy='MKV enforced'
            ;;
        *)
            die "Invalid mode: $mode"
            ;;
    esac
}

choose_extras() {
    subtitle_args=()
    sidecar_args=()
    if [[ "$mode" == 3 ]]; then
        sidecar_args=(--embed-thumbnail)
        return 0
    fi
    say "Subtitle options"
    printf '%sEmbed English subtitles when available?%s [Y/n]: ' "$YELLOW" "$RESET"
    read -r choice
    if [[ ! "$choice" =~ ^[Nn]$ ]]; then
        subtitle_args=(--embed-subs --sub-langs 'en.*,en' --write-subs --write-auto-subs)
    fi
    say "Archival sidecars"
    printf '%sSave info JSON, description, and thumbnail beside each file?%s [Y/n]: ' "$YELLOW" "$RESET"
    read -r choice
    if [[ ! "$choice" =~ ^[Nn]$ ]]; then
        sidecar_args=(--write-info-json --write-description --write-thumbnail --embed-thumbnail)
    fi
    return 0
}

choose_cookies() {
    say "YouTube authentication"
    printf '%sUse browser cookies to reduce 403/bot-check errors?%s [Y/n]: ' "$YELLOW" "$RESET"
    read -r choice
    cookie_args=()
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        return 0
    fi
    printf '1) Firefox\n2) Chromium\n3) Chromium + KWallet 6\n4) Brave\n5) Custom browser identifier\n'
    printf '%sChoose%s [1]: ' "$YELLOW" "$RESET"
    read -r browser_choice
    case "${browser_choice:-1}" in
        1) browser='firefox' ;;
        2) browser='chromium' ;;
        3) browser='chromium+kwallet6' ;;
        4) browser='brave' ;;
        5)
            printf '%sBrowser identifier%s: ' "$YELLOW" "$RESET"
            read -r browser
            [[ -n "$browser" ]] || die "No browser supplied."
            ;;
        *)
            die "Invalid browser selection."
            ;;
    esac
    cookie_args=(--cookies-from-browser "$browser")
    return 0
}

classify_url() {
    local target="$1"
    if [[ "$target" == *'list='* ]] || [[ "$target" == *'/playlist'* ]] || [[ "$target" == *'/charts'* ]] \
        || [[ "$target" == *'/channel/'*'/playlists'* ]] || [[ "$target" == *'/channel/'*'/releases'* ]] \
        || [[ "$target" == *'/podcasts/'* ]] || [[ "$target" == *'/album/'* ]]; then
        url_kind='playlist'
    else
        url_kind='single'
    fi
}

set_output_template() {
    classify_url "$url"
    # Relative templates allow yt-dlp's home and temp paths to work together.
    if [[ "$url_kind" == 'playlist' ]]; then
        output_template='playlists/%(playlist_title)s/%(playlist_index)02d - %(title)s.%(ext)s'
    else
        output_template='singles/%(title)s [%(id)s].%(ext)s'
    fi
}

get_playlist_total() {
    playlist_total='N/A'
    if [[ "$url_kind" != 'playlist' ]]; then
        return 0
    fi
    local count
    count=$(yt-dlp --flat-playlist --playlist-end 1 --no-warnings --color never \
        --print '%(playlist_count)s' "$url" 2>/dev/null | head -n 1 || true)
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        playlist_total="$count"
    fi
    return 0
}

debug_yt_dlp_args() {
    if [[ "${STREAMCACHE_DEBUG:-}" != 1 ]]; then
        return 0
    fi
    printf '%sOutput template:%s %q\n' "$DIM" "$RESET" "$output_template"
    printf '%syt-dlp arguments:%s\n' "$DIM" "$RESET"
    printf ' %q\n' "${yt_dlp_args[@]}"
}

build_yt_dlp_args() {
    local purpose="$1"
    yt_dlp_args=(yt-dlp)
    if [[ "$purpose" == 'simulate' ]]; then
        yt_dlp_args+=(--simulate --yes-playlist --ignore-errors --color never)
    else
        yt_dlp_args=(
            yt-dlp --yes-playlist --continue --no-overwrites
            --download-archive "$archive_file"
            --ignore-errors --embed-metadata --embed-chapters
            --sleep-interval 2 --max-sleep-interval 6
            --retries 10 --fragment-retries 10
            --color never --newline
            --progress-template 'download:SC_DOWNLOAD|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress._speed_str)s|%(progress._eta_str)s'
            --progress-template 'postprocess:SC_POST|%(progress.postprocessor)s|%(progress.status)s'
        )
    fi
    yt_dlp_args+=(-P "home:${output_dir}" -P "temp:${temp_dir}")
    yt_dlp_args+=("${format_args[@]}" "${container_args[@]}" "${subtitle_args[@]}" "${cookie_args[@]}" "${sidecar_args[@]}")
    yt_dlp_args+=(--output "$output_template" "$url")
    debug_yt_dlp_args
}

configure_run() {
    choose_download_mode
    choose_extras
    choose_cookies
    playlists_dir="$output_dir/playlists"
    singles_dir="$output_dir/singles"
    temp_dir="$output_dir/.streamcache-tmp"
    archive_file="$output_dir/archive/downloaded.txt"
    run_log="$output_dir/logs/streamcache-$(date '+%Y%m%d-%H%M%S').log"
    set_output_template
    get_playlist_total
    return 0
}

show_plan() {
    say "Run plan"
    printf '%sSource:%s %s\n' "$CYAN" "$RESET" "$url"
    printf '%sURL kind:%s %s\n' "$CYAN" "$RESET" "$url_kind"
    printf '%sPlaylist items:%s %s\n' "$CYAN" "$RESET" "$playlist_total"
    printf '%sArchive root:%s %s\n' "$CYAN" "$RESET" "$output_dir"
    printf '%sPlaylists:%s %s\n' "$CYAN" "$RESET" "$playlists_dir"
    printf '%sSingles:%s %s\n' "$CYAN" "$RESET" "$singles_dir"
    printf '%sTemporary files:%s %s\n' "$CYAN" "$RESET" "$temp_dir"
    printf '%sOutput template:%s %s\n' "$CYAN" "$RESET" "$output_template"
    printf '%sSelected streams:%s %s\n' "$CYAN" "$RESET" "$format_description"
    printf '%sContainer policy:%s %s\n' "$CYAN" "$RESET" "$container_policy"
    printf '%sArchive index:%s %s\n' "$CYAN" "$RESET" "$archive_file"
}

run_dry_run() {
    show_plan
    say "DRY RUN - no media, sidecars, logs, temporary files, or archive updates will be written"
    build_yt_dlp_args simulate
    "${yt_dlp_args[@]}"
    say "Simulation complete. No files were created."
}

sanitize_progress_text() {
    local value="${1:-}"
    value=${value//$'\r'/}
    value=${value//$'\n'/}
    printf '%s' "$value"
}

show_hash_bar() {
    local downloaded="${1:-0}" exact_total="${2:-0}" estimated_total="${3:-0}"
    local speed="${4:-N/A}" eta="${5:-N/A}"
    local total=0 percent='' width=40 filled empty filled_bar empty_bar
    speed=$(sanitize_progress_text "$speed")
    eta=$(sanitize_progress_text "$eta")
    if [[ ! "$speed" =~ ^[0-9.]+[[:alpha:]]+/s$|^N/A$|^Unknown$ ]]; then
        speed='N/A'
    fi
    if [[ ! "$eta" =~ ^[0-9]+:[0-9]{2}(:[0-9]{2})?$|^N/A$|^Unknown$ ]]; then
        eta='N/A'
    fi
    if [[ ! "$downloaded" =~ ^[0-9]+$ ]]; then
        downloaded=0
    fi
    if [[ ! "$exact_total" =~ ^[0-9]+$ ]]; then
        exact_total=0
    fi
    if [[ ! "$estimated_total" =~ ^[0-9]+$ ]]; then
        estimated_total=0
    fi
    if (( exact_total > 0 )); then
        total=$exact_total
    elif (( estimated_total > 0 )); then
        total=$estimated_total
    fi
    if (( total > 0 )); then
        percent=$(awk -v done="$downloaded" -v size="$total" 'BEGIN { p=(done*100)/size; if(p<0)p=0; if(p>100)p=100; printf "%.1f", p }')
        filled=$(awk -v p="$percent" -v w="$width" 'BEGIN { n=int((p*w/100)+0.5); if(n<0)n=0; if(n>w)n=w; print n }')
        empty=$((width - filled))
        printf -v filled_bar '%*s' "$filled" ''; filled_bar=${filled_bar// /#}
        printf -v empty_bar '%*s' "$empty" ''; empty_bar=${empty_bar// /-}
        printf '\r[%s%s%s%s%s] %s%5.1f%%%s %s%-10s%s %sETA %s%s' \
            "$GREEN" "$filled_bar" "$GRAY" "$empty_bar" "$RESET" \
            "$GREEN" "$percent" "$RESET" "$CYAN" "$speed" "$RESET" "$DIM" "$eta" "$RESET"
    else
        printf -v empty_bar '%*s' "$width" ''; empty_bar=${empty_bar// /?}
        printf '\r[%s%s%s] %s   ?%%%s %s%-10s%s %sETA %s%s' \
            "$YELLOW" "$empty_bar" "$RESET" "$YELLOW" "$RESET" "$CYAN" "$speed" "$RESET" "$DIM" "$eta" "$RESET"
    fi
}

completed=0
skipped=0
failed=0
last_stage=''
counts_file=''
playlist_total='N/A'

log_and_print() {
    printf '\r\033[K%s\n' "$1"
    printf '%s\n' "$1" >> "$run_log"
}

process_output() {
    local line kind downloaded exact_total estimated_total speed eta a b stage
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == SC_DOWNLOAD\|* ]]; then
            IFS='|' read -r kind downloaded exact_total estimated_total speed eta <<< "$line"
            show_hash_bar "$downloaded" "$exact_total" "$estimated_total" "$speed" "$eta"
        elif [[ "$line" == SC_POST\|* ]]; then
            IFS='|' read -r kind a b <<< "$line"
            case "${a,,}" in
                *merger*|*remux*|*fixup*) stage='[2/3] Merging or remuxing streams' ;;
                *extractaudio*|*ffmpegextractaudio*) stage='[2/3] Converting to MP3' ;;
                *metadata*|*thumbnail*|*subtitle*|*chapter*) stage='[3/3] Embedding metadata and optional extras' ;;
                *) stage='[2/3] Processing downloaded media' ;;
            esac
            if [[ "$stage" != "$last_stage" ]]; then
                if [[ "$stage" == '[2/3]'* ]]; then
                    log_and_print "${MAGENTA}${stage}${RESET}"
                else
                    log_and_print "${CYAN}${stage}${RESET}"
                fi
                last_stage="$stage"
            fi
        else
            if [[ "$line" =~ ^\[download\]\ Downloading\ item\ ([0-9]+)\ of\ ([0-9]+)$ ]]; then
                log_and_print "${CYAN}${BOLD}Downloading item ${YELLOW}${BASH_REMATCH[1]} of ${BASH_REMATCH[2]}${RESET}"
                continue
            fi
            if [[ "$line" == *'has already been recorded in the archive'* ]]; then
                skipped=$((skipped + 1))
            fi
            if [[ "$line" == ERROR:* ]]; then
                failed=$((failed + 1))
            fi
            log_and_print "$line"
        fi
    done
    printf '%d %d\n' "$skipped" "$failed" > "$counts_file"
}

run_download() {
    local status before after
    : > "$run_log" || die "Could not create run log: $run_log"
    completed=0
    skipped=0
    failed=0
    last_stage=''
    counts_file="$(mktemp)"
    before=$(wc -l < "$archive_file" 2>/dev/null || echo 0)
    if [[ "$mode" == 3 ]]; then
        log_and_print "${CYAN}[1/3] Downloading audio${RESET}"
    else
        log_and_print "${CYAN}[1/3] Downloading video and audio${RESET}"
    fi
    build_yt_dlp_args download
    set +e
    "${yt_dlp_args[@]}" 2>&1 | process_output
    status=${PIPESTATUS[0]}
    set -e
    printf '\r\033[K'
    if [[ -s "$counts_file" ]]; then
        read -r skipped failed < "$counts_file"
    fi
    rm -f "$counts_file"
    counts_file=''
    after=$(wc -l < "$archive_file" 2>/dev/null || echo 0)
    completed=$((after - before))
    if (( status == 0 )); then
        return 0
    fi
    return "$status"
}

show_summary() {
    local items_processed
    items_processed=$((completed + skipped + failed))
    printf '\n%s%sResults summary%s\n' "$CYAN" "$BOLD" "$RESET"
    printf '%-22s %s%s%s\n' 'Playlist items:' "$CYAN" "$playlist_total" "$RESET"
    printf '%-22s %s%s%s\n' 'Items processed:' "$CYAN" "$items_processed" "$RESET"
    printf '%-22s %s%s%s\n' 'Completed:' "$GREEN" "$completed" "$RESET"
    printf '%-22s %s%s%s\n' 'Skipped from archive:' "$YELLOW" "$skipped" "$RESET"
    printf '%-22s %s%s%s\n' 'Failed:' "$RED" "$failed" "$RESET"
    printf '%-22s %s%s%s\n' 'Run log:' "$DIM" "$run_log" "$RESET"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
show_banner
command -v yt-dlp >/dev/null 2>&1 || die "yt-dlp is not installed. On openSUSE: sudo zypper install yt-dlp"
update_yt_dlp
if ! command -v ffmpeg >/dev/null 2>&1; then
    warn "ffmpeg is required for merging, remuxing, MP3 conversion, and embedded metadata."
    printf '%sInstall ffmpeg with zypper now?%s [Y/n]: ' "$YELLOW" "$RESET"
    read -r choice
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        die "Cannot continue without ffmpeg."
    fi
    sudo zypper install -y ffmpeg || die "ffmpeg installation failed."
fi

output_dir="$DEFAULT_OUTPUT_DIR"
set_output_dir
say "YouTube / YouTube Music URL"
printf '%sPaste a YouTube or YouTube Music video, playlist, or album URL:%s ' "$YELLOW" "$RESET"
read -r url
[[ -n "$url" ]] || die "No URL supplied."

while true; do
    say "Main menu"
    printf '%sSource:%s %s\n%sArchive root:%s %s\n\n' "$CYAN" "$RESET" "$url" "$CYAN" "$RESET" "$output_dir"
    printf '1) Inspect URL\n2) Start download\n3) Dry run / preview download\n4) Change download location\n5) Change URL\n6) Exit\n'
    printf '%sChoose%s [1]: ' "$YELLOW" "$RESET"
    read -r action
    case "${action:-1}" in
        1)
            inspect_source
            ;;
        2)
            configure_run
            show_plan
            printf '%sStart download?%s [Y/n]: ' "$YELLOW" "$RESET"
            read -r choice
            if [[ ! "$choice" =~ ^[Nn]$ ]]; then
                break
            fi
            ;;
        3)
            configure_run
            run_dry_run
            ;;
        4)
            set_output_dir
            ;;
        5)
            printf '%sPaste replacement URL:%s ' "$YELLOW" "$RESET"
            read -r replacement_url
            if [[ -n "$replacement_url" ]]; then
                url="$replacement_url"
            else
                warn "URL unchanged."
            fi
            ;;
        6)
            say "Cancelled."
            exit 0
            ;;
        *)
            warn "Invalid selection."
            ;;
    esac
done

download_status=0
run_download || download_status=$?
if (( download_status == 0 )); then
    say "Finished. Completed media is in: $output_dir"
else
    warn "yt-dlp exited with status $download_status. Completed files and staging files remain intact for a safe retry."
fi
show_summary
