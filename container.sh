#!/usr/bin/env bash
# Docker Container Auto-Updater
# A simple, safe tool to update Docker containers with auto-rollback.

set -Eeuo pipefail
shopt -s extglob 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/.env}"

# Defaults
CONTAINER_NAME="${CONTAINER_NAME:-}"
IMAGE_NAME="${IMAGE_NAME:-}"
STOP_TIMEOUT="${STOP_TIMEOUT:-15}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-3}"
HEALTH_URL="${HEALTH_URL:-}"
HEALTH_CMD="${HEALTH_CMD:-}"
AUTO_PRUNE="${AUTO_PRUNE:-true}"
FORCE_UPDATE="${FORCE_UPDATE:-false}"
BACKUP_SUFFIX="${BACKUP_SUFFIX:-_rollback}"
WATCH_INTERVAL="${WATCH_INTERVAL:-60}"
WEBHOOK_PORT="${WEBHOOK_PORT:-9000}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"
COMPOSE_FILE="${COMPOSE_FILE:-}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
SKIP_PULL="${SKIP_PULL:-false}"
INTERACTIVE_MODE="${INTERACTIVE_MODE:-false}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
LOG_FILE="${LOG_FILE:-}"

NO_ANIMATION="${NO_ANIMATION:-false}"
NO_COLOR="${NO_COLOR:-}"

# Rich Modern Terminal Colors & Styles
init_colors() {
    if [ -n "${NO_COLOR:-}" ] || [ "${NO_COLOR:-false}" = "true" ] || [ "${TERM:-}" = "dumb" ]; then
        C_RESET=""
        C_BOLD=""
        C_DIM=""
        C_GREEN=""
        C_RED=""
        C_YELLOW=""
        C_CYAN=""
        C_BLUE=""
        C_MAGENTA=""
        C_GRAY=""
    else
        C_RESET="\033[0m"
        C_BOLD="\033[1m"
        C_DIM="\033[2m"
        C_GREEN="\033[38;5;78m"
        C_RED="\033[38;5;203m"
        C_YELLOW="\033[38;5;220m"
        C_CYAN="\033[38;5;75m"
        C_BLUE="\033[38;5;39m"
        C_MAGENTA="\033[38;5;177m"
        C_GRAY="\033[38;5;244m"
    fi

    # Icons & Indicators
    I_STEP="${C_CYAN}›${C_RESET}"
    I_OK="${C_GREEN}✔${C_RESET}"
    I_ERR="${C_RED}✖${C_RESET}"
    I_WARN="${C_YELLOW}▲${C_RESET}"
    I_BULLET="${C_GRAY}•${C_RESET}"
}
init_colors

# Animation & UX Assets
SPIN_CHARS=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
BAR_FULL="████████████████████"
BAR_EMPTY="░░░░░░░░░░░░░░░░░░░░"

is_interactive_tty() {
    [ -t 1 ] && [ "${NO_ANIMATION}" != "true" ] && [ "${TERM:-}" != "dumb" ]
}

clear_screen() {
    clear 2>/dev/null || printf "\033[2J\033[H" 2>/dev/null || true
}

IS_FULLSCREEN="false"

enter_fullscreen() {
    if is_interactive_tty && [ "$IS_FULLSCREEN" != "true" ]; then
        IS_FULLSCREEN="true"
        tput smcup 2>/dev/null || echo -ne "\033[?1049h"
        # Turn off alternate scroll mode (DEC 1007) so mouse scrolling does NOT emit cursor keys
        echo -ne "\033[?1007l" 2>/dev/null || true
        # Also turn off any xterm mouse tracking modes to prevent mouse reporting escape codes
        echo -ne "\033[?1000l\033[?1002l\033[?1003l\033[?1006l" 2>/dev/null || true
        clear_screen
    fi
}

exit_fullscreen() {
    if [ "$IS_FULLSCREEN" = "true" ]; then
        IS_FULLSCREEN="false"
        # Restore alternate scroll mode and leave alternate screen buffer
        echo -ne "\033[?1007h" 2>/dev/null || true
        echo -ne "\033[?1000l\033[?1002l\033[?1003l\033[?1006l" 2>/dev/null || true
        tput rmcup 2>/dev/null || echo -ne "\033[?1049l"
    fi
    if [ -t 1 ]; then
        echo -ne "\033[?25h\033[0m" 2>/dev/null || true
        stty echo icanon < /dev/stdin 2>/dev/null || true
    fi
}

cleanup_terminal() {
    exit_fullscreen
    stty echo icanon < /dev/stdin 2>/dev/null || true
}
trap cleanup_terminal EXIT INT TERM

# Safe line reader that silently absorbs mouse scroll and arrow escape sequences
safe_read_line() {
    local prompt="$1"
    local default_val="${2:-}"
    local -n out_var="$3"
    local input_str=""

    printf "%s" "$prompt"

    if [ ! -t 0 ]; then
        if IFS= read -r input_str; then
            input_str="${input_str%$'\r'}"
            out_var="${input_str:-$default_val}"
            return 0
        else
            return 1
        fi
    fi

    # Disable tty echo so escape sequences/scroll codes are NEVER echoed by the driver
    stty -echo < /dev/stdin 2>/dev/null || true

    # Drain any buffered escape sequences before reading
    while read -rsn10 -t 0.001 _discard 2>/dev/null; do :; done

    while true; do
        local char=""
        IFS= read -rsn1 char || break

        # Enter key finishes line
        if [ "$char" = "" ] || [ "$char" = $'\n' ] || [ "$char" = $'\r' ]; then
            printf "\n"
            break
        fi

        # Escape sequences: swallow the entire sequence!
        # Covers cursor keys, DEC 1007 scroll keys, SGR mouse reporting (\033[<...M)
        if [ "$char" = $'\033' ]; then
            local next_ch=""
            while read -rsn1 -t 0.05 next_ch; do
                if [[ "$next_ch" =~ [A-Za-z~] ]]; then
                    break
                fi
            done
            continue
        fi

        # Backspace / Delete
        if [ "$char" = $'\177' ] || [ "$char" = $'\b' ]; then
            if [ -n "$input_str" ]; then
                input_str="${input_str%?}"
                printf "\b \b"
            fi
            continue
        fi

        # Ctrl+C
        if [ "$char" = $'\003' ]; then
            stty echo icanon < /dev/stdin 2>/dev/null || true
            printf "\n"
            exit 130
        fi

        # Ctrl+U (erase whole line)
        if [ "$char" = $'\025' ]; then
            while [ -n "$input_str" ]; do
                input_str="${input_str%?}"
                printf "\b \b"
            done
            continue
        fi

        input_str+="$char"
        printf "%s" "$char"
    done

    stty echo icanon < /dev/stdin 2>/dev/null || true

    input_str="$(echo "$input_str" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    out_var="${input_str:-$default_val}"
    return 0
}

# Single-key menu reader that silently absorbs mouse scroll and arrow escape sequences
get_menu_choice() {
    local -n out_key="$1"
    out_key=""

    if [ ! -t 0 ]; then
        if read -r out_key; then
            return 0
        else
            return 1
        fi
    fi

    stty -echo < /dev/stdin 2>/dev/null || true

    # Drain any buffered escape sequences before reading
    while read -rsn10 -t 0.001 _discard 2>/dev/null; do :; done

    while true; do
        local key=""
        IFS= read -rsn1 key || break

        # Swallow escape sequences (mouse wheel scrolls, arrows, F-keys)
        if [ "$key" = $'\033' ]; then
            local next_ch=""
            while read -rsn1 -t 0.05 next_ch; do
                if [[ "$next_ch" =~ [A-Za-z~] ]]; then
                    break
                fi
            done
            continue
        fi

        # Ignore empty key or accidental enter
        if [ -z "$key" ]; then
            continue
        fi

        # Check for Ctrl+C
        if [ "$key" = $'\003' ]; then
            stty echo icanon < /dev/stdin 2>/dev/null || true
            exit 130
        fi

        if [[ "$key" =~ ^[0-6qQ]$ ]]; then
            printf "%s\n" "$key"
            out_key="$key"
            stty echo icanon < /dev/stdin 2>/dev/null || true
            return 0
        fi
    done

    stty echo icanon < /dev/stdin 2>/dev/null || true
    return 1
}

pause_and_return() {
    if [ "${INTERACTIVE_MODE:-false}" = "true" ] && is_interactive_tty; then
        echo ""
        echo -e "  ${C_DIM}───────────────────────────────────────────────────────────────────────────${C_RESET}"
        printf "  Press [Enter] to return to dashboard... "
        stty -echo < /dev/stdin 2>/dev/null || true
        # Drain any buffered escape sequences before waiting
        while read -rsn10 -t 0.001 _discard 2>/dev/null; do :; done

        while true; do
            local key=""
            IFS= read -rsn1 key || break

            # Swallow escape sequences (scrolls, arrows, mouse codes)
            if [ "$key" = $'\033' ]; then
                local next_ch=""
                while read -rsn1 -t 0.05 next_ch; do
                    if [[ "$next_ch" =~ [A-Za-z~] ]]; then
                        break
                    fi
                done
                continue
            fi

            # Check for Enter or Ctrl+C
            if [ -z "$key" ] || [ "$key" = $'\n' ] || [ "$key" = $'\r' ]; then
                break
            fi
            if [ "$key" = $'\003' ]; then
                stty echo icanon < /dev/stdin 2>/dev/null || true
                exit 130
            fi
        done
        stty echo icanon < /dev/stdin 2>/dev/null || true
        echo ""
    fi
}

# Run command with interactive spinner
run_with_spinner() {
    local label="$1"
    shift

    if ! is_interactive_tty; then
        log_info "${label}..."
        "$@"
        local rc=$?
        return $rc
    fi

    # Hide cursor
    echo -ne "\033[?25l"

    local tmp_err
    tmp_err=$(mktemp)

    "$@" > "$tmp_err" 2>&1 &
    local cmd_pid=$!
    local frame_i=0
    local start_time
    start_time=$(date +%s)

    while kill -0 "$cmd_pid" 2>/dev/null; do
        local frame="${SPIN_CHARS[$((frame_i % ${#SPIN_CHARS[@]}))]}"
        local elapsed=$(( $(date +%s) - start_time ))
        printf "\r  ${C_CYAN}%s${C_RESET} %s ${C_DIM}(%ds)${C_RESET}\033[K" "$frame" "$label" "$elapsed"
        ((frame_i++)) || true
        sleep 0.08
    done

    local exit_code=0
    set +e
    wait "$cmd_pid"
    exit_code=$?
    set -e

    local total_time=$(( $(date +%s) - start_time ))

    echo -ne "\033[?25h"

    if [ $exit_code -eq 0 ]; then
        printf "\r  ${I_OK} %s ${C_DIM}(%ds)${C_RESET}\033[K\n" "$label" "$total_time"
        log_to_file "OK" "$label ($total_time s)"
    else
        printf "\r  ${I_ERR} %s ${C_DIM}(%ds)${C_RESET}\033[K\n" "$label" "$total_time"
        log_to_file "ERROR" "$label failed ($total_time s)"
        if [ -s "$tmp_err" ]; then
            sed 's/^/    /' "$tmp_err" >&2
        fi
    fi

    rm -f "$tmp_err"
    return $exit_code
}

show_banner() {
    echo -e "  ${C_CYAN}╭────────────────────────────────────────────────────────────╮${C_RESET}"
    echo -e "  ${C_CYAN}│${C_RESET} ${C_BOLD}${C_CYAN}🐳  D O C K E R   A U T O - U P D A T E R   v 2 . 0${C_RESET}        ${C_CYAN}│${C_RESET}"
    echo -e "  ${C_CYAN}│${C_RESET}   ${C_DIM}Zero-Downtime Deployments • Safe Healthchecks • Rollback${C_RESET} ${C_CYAN}│${C_RESET}"
    echo -e "  ${C_CYAN}╰────────────────────────────────────────────────────────────╯${C_RESET}"
}

# Output Functions
log_step()    { echo -e "${I_STEP} ${C_BOLD}$*${C_RESET}"; log_to_file "STEP" "$*"; }
log_success() { echo -e "${I_OK} $*"; log_to_file "OK" "$*"; }
log_info()    { echo -e "  ${I_BULLET} $*"; log_to_file "INFO" "$*"; }
log_warn()    { echo -e "${I_WARN} $*"; log_to_file "WARN" "$*"; }
log_error()   { echo -e "${I_ERR} $*"; log_to_file "ERROR" "$*"; }

debug() {
    if [ "${VERBOSE}" = "true" ]; then
        echo -e "  ${C_DIM}[debug] $*${C_RESET}"
        log_to_file "DEBUG" "$*"
    fi
}

log_to_file() {
    local level="$1"
    shift
    if [ -n "${LOG_FILE:-}" ]; then
        local ts
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        echo "[${ts}] [${level}] $*" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

# Notifications (Slack / Discord)
send_notification() {
    local status="$1"
    local message="$2"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
        local color_dec=3066993 # Green
        [ "$status" = "ROLLBACK" ] && color_dec=15158332 # Red
        [ "$status" = "WARN" ] && color_dec=15105570 # Yellow

        local payload
        payload=$(jq -n \
            --arg title "Docker Deployment: ${status}" \
            --arg desc "${message}" \
            --arg footer "Container: ${CONTAINER_NAME:-unknown} | ${ts}" \
            --argjson color "${color_dec}" \
            '{embeds: [{title: $title, description: $desc, color: $color, footer: {text: $footer}}]}')
        curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
    fi

    if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
        local icon=":white_check_mark:"
        [ "$status" = "ROLLBACK" ] && icon=":rotating_light:"
        [ "$status" = "WARN" ] && icon=":warning:"
        local payload
        payload=$(jq -n --arg text "${icon} *Docker Auto-Updater (${status})*: ${message}" '{"text": $text}')
        curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
}

# Check Docker and tools
check_dependencies() {
    local missing=()
    for cmd in docker jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        echo "  Please install them first (e.g. sudo apt install -y ${missing[*]})."
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        log_error "Cannot connect to Docker. Is Docker running?"
        exit 1
    fi
}

# Load .env file
load_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        debug "Loading settings from: ${CONFIG_FILE}"
        while IFS='=' read -r key value || [ -n "$key" ]; do
            key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//")
            if [ -z "${!key:-}" ]; then
                export "$key"="$value"
            fi
        done < "${CONFIG_FILE}"
    fi
}

# Generate arguments to recreate the container
generate_run_args() {
    local inspect_target="$1"
    local target_image="$2"

    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import subprocess, json, sys

target = sys.argv[1]
image = sys.argv[2]
try:
    raw = subprocess.check_output(["docker", "inspect", target], stderr=subprocess.DEVNULL)
    data = json.loads(raw)[0]
except Exception:
    sys.exit(1)

hc = data.get("HostConfig", {})
cfg = data.get("Config", {})
ns = data.get("NetworkSettings", {})

args = []

# Restart policy
rp = hc.get("RestartPolicy", {}).get("Name")
if rp and rp != "no":
    retry = hc.get("RestartPolicy", {}).get("MaximumRetryCount", 0)
    args.append(f"--restart={rp}" + (f":{retry}" if retry > 0 else ""))

# Primary Network
networks = list(ns.get("Networks", {}).keys())
if networks and networks[0] not in ["bridge", "default"]:
    args.append(f"--network={networks[0]}")

# Port bindings
pb = hc.get("PortBindings") or {}
for cport, bindings in pb.items():
    for b in (bindings or []):
        hp = b.get("HostPort", "")
        hip = b.get("HostIp", "")
        if hip and hip not in ["0.0.0.0", "::"]:
            args.append(f"-p={hip}:{hp}:{cport}")
        else:
            args.append(f"-p={hp}:{cport}")

# Volume mounts
binds = hc.get("Binds") or []
for b in binds:
    args.append(f"-v={b}")

# Environment variables
envs = cfg.get("Env") or []
for e in envs:
    args.append(f"-e={e}")

# Working Dir
wd = cfg.get("WorkingDir")
if wd:
    args.append(f"-w={wd}")

# User
usr = cfg.get("User")
if usr:
    args.append(f"-u={usr}")

# Privileged
if hc.get("Privileged"):
    args.append("--privileged")

# Labels (skip compose internal labels)
labels = cfg.get("Labels") or {}
for k, v in labels.items():
    if not k.startswith("com.docker.compose."):
        args.append(f"--label={k}={v}")

print(json.dumps(args))
' "$inspect_target" "$target_image"
    else
        # Fallback using jq
        docker inspect "$inspect_target" | jq -c '
            .[0] as $c |
            [
                (if $c.HostConfig.RestartPolicy.Name != "" and $c.HostConfig.RestartPolicy.Name != "no" then
                    "--restart=" + $c.HostConfig.RestartPolicy.Name + (if $c.HostConfig.RestartPolicy.MaximumRetryCount > 0 then ":" + ($c.HostConfig.RestartPolicy.MaximumRetryCount|tostring) else "" end)
                else empty end),
                (if ($c.NetworkSettings.Networks | keys | length) > 0 and ($c.NetworkSettings.Networks | keys | .[0]) != "bridge" then
                    "--network=" + ($c.NetworkSettings.Networks | keys | .[0])
                else empty end),
                ($c.HostConfig.PortBindings | to_entries[]? | .key as $cport | .value[]? |
                    "-p=" + (if .HostIp != "" and .HostIp != "0.0.0.0" and .HostIp != "::" then .HostIp + ":" else "" end) + .HostPort + ":" + $cport
                ),
                ($c.HostConfig.Binds[]? | "-v=" + .),
                ($c.Config.Env[]? | "-e=" + .)
            ]
        '
    fi
}

# Safely stop a container
stop_container_gracefully() {
    local target="$1"
    local timeout="${2:-15}"

    if ! docker inspect "$target" >/dev/null 2>&1; then
        return 0
    fi

    local is_running
    is_running=$(docker inspect --format '{{.State.Running}}' "$target" 2>/dev/null || echo "false")
    if [ "$is_running" = "true" ]; then
        if is_interactive_tty; then
            run_with_spinner "Stopping old container safely (giving up to ${timeout}s)" docker stop -t "$timeout" "$target"
            log_info "Old container stopped."
        else
            log_info "Stopping old container safely (giving it up to ${timeout}s)..."
            docker stop -t "$timeout" "$target" >/dev/null
            log_info "Old container stopped."
        fi
    fi
}

# Check if the new container is healthy
verify_container_health() {
    local target="$1"
    local timeout="${2:-60}"
    local interval="${3:-3}"
    local health_url="${4:-}"
    local health_cmd="${5:-}"

    if ! is_interactive_tty; then
        log_info "Checking if container is healthy (waiting up to ${timeout}s)..."
    fi

    local elapsed=0
    local start_time
    start_time=$(date +%s)
    local stable_seconds=0
    local min_stable=8
    local spin_idx=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local is_running exit_code
        is_running=$(docker inspect --format '{{.State.Running}}' "$target" 2>/dev/null || echo "false")
        exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$target" 2>/dev/null || echo "-1")

        if [ "$is_running" != "true" ]; then
            if is_interactive_tty; then printf "\r\033[K"; fi
            log_error "Container stopped unexpectedly! (Exit code: ${exit_code})"
            return 1
        fi

        local health_status
        health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$target" 2>/dev/null || echo "none")

        if [ "$health_status" = "healthy" ]; then
            if is_interactive_tty; then printf "\r\033[K"; fi
            log_success "Container is healthy and working! (${elapsed}s)"
            return 0
        elif [ "$health_status" = "unhealthy" ]; then
            if is_interactive_tty; then printf "\r\033[K"; fi
            log_error "Container health check failed!"
            local log_entries
            log_entries=$(docker inspect --format '{{range .State.Health.Log}}{{.Output}}{{end}}' "$target" 2>/dev/null || true)
            if [ -n "$log_entries" ]; then
                echo -e "  ${C_DIM}${log_entries}${C_RESET}"
            fi
            return 1
        elif [ "$health_status" = "starting" ]; then
            debug "Health check is starting... (${elapsed}s elapsed)"
        elif [ "$health_status" = "none" ]; then
            if [ -n "$health_url" ]; then
                debug "Checking health URL: ${health_url}"
                if curl -s -f -m 3 "$health_url" >/dev/null 2>&1; then
                    if is_interactive_tty; then printf "\r\033[K"; fi
                    log_success "Health check URL returned OK! (${elapsed}s)"
                    return 0
                fi
            elif [ -n "$health_cmd" ]; then
                debug "Running custom health command: ${health_cmd}"
                if eval "$health_cmd" >/dev/null 2>&1; then
                    if is_interactive_tty; then printf "\r\033[K"; fi
                    log_success "Custom health command passed!"
                    return 0
                fi
            else
                stable_seconds=$((stable_seconds + interval))
                if [ "$stable_seconds" -ge "$min_stable" ]; then
                    if is_interactive_tty; then printf "\r\033[K"; fi
                    log_success "Container is running stably with no crashes."
                    return 0
                fi
            fi
        fi

        if is_interactive_tty; then
            local pct=$(( elapsed * 100 / (timeout > 0 ? timeout : 1) ))
            [ "$pct" -gt 100 ] && pct=100
            local bar_len=14
            local filled=$(( pct * bar_len / 100 ))
            local empty=$(( bar_len - filled ))
            local bar_f="${BAR_FULL:0:filled}"
            local bar_e="${BAR_EMPTY:0:empty}"

            local status_text="starting"
            [ "$health_status" != "none" ] && status_text="$health_status"
            [ "$health_status" = "none" ] && [ -n "$health_url" ] && status_text="probing HTTP"
            [ "$health_status" = "none" ] && [ -n "$health_cmd" ] && status_text="evaluating command"
            [ "$health_status" = "none" ] && [ -z "$health_url" ] && [ -z "$health_cmd" ] && status_text="testing stability (${stable_seconds}/${min_stable}s)"

            local steps=$(( interval * 10 ))
            for (( s=0; s<steps; s++ )); do
                local frame="${SPIN_CHARS[$((spin_idx % ${#SPIN_CHARS[@]}))]}"
                ((spin_idx++)) || true
                printf "\r  ${C_CYAN}%s${C_RESET} Checking health: ${C_BOLD}[%02ds/%02ds]${C_RESET} ${C_CYAN}[%s%s]${C_RESET} ${C_DIM}(Status: %s)${C_RESET}\033[K" \
                    "$frame" "$elapsed" "$timeout" "$bar_f" "$bar_e" "$status_text"
                sleep 0.1
            done
        else
            sleep "$interval"
        fi

        local now
        now=$(date +%s)
        elapsed=$((now - start_time))
    done

    if is_interactive_tty; then printf "\r\033[K"; fi
    log_error "Health check timed out after ${timeout}s without becoming healthy."
    return 1
}

# Roll back to the previous working container
rollback_container() {
    local target="$1"
    local backup_target="${target}${BACKUP_SUFFIX}"

    echo ""
    echo -e "  ${C_RED}╭── HEALTH VERIFICATION FAILED ───────────────────────────╮${C_RESET}"
    echo -e "  ${C_RED}│${C_RESET}  The new container failed health checks.                   ${C_RED}│${C_RESET}"
    echo -e "  ${C_RED}│${C_RESET}  Initiating auto-rollback to guarantee zero downtime...    ${C_RED}│${C_RESET}"
    echo -e "  ${C_RED}╰─────────────────────────────────────────────────────────╯${C_RESET}"
    log_warn "Health check failed! Rolling back to previous version..."

    if docker inspect "$target" >/dev/null 2>&1; then
        echo -e "\n${C_DIM}--- Recent Container Logs ---${C_RESET}"
        docker logs --tail 25 "$target" 2>&1 || true
        echo -e "${C_DIM}------------------------------${C_RESET}\n"

        log_info "Removing failed container..."
        docker rm -f "$target" >/dev/null 2>&1 || true
    fi

    if ! docker inspect "$backup_target" >/dev/null 2>&1; then
        log_error "Cannot rollback: backup container '${backup_target}' not found."
        send_notification "ROLLBACK" "Failed deployment of '${target}', no backup found."
        return 1
    fi

    log_info "Restoring previous container from backup..."
    docker rename "$backup_target" "$target"
    docker start "$target" >/dev/null

    local restored_running
    restored_running=$(docker inspect --format '{{.State.Running}}' "$target" 2>/dev/null || echo "false")

    if [ "$restored_running" = "true" ]; then
        log_success "Rollback complete! Old container is safely back online."
        send_notification "ROLLBACK" "Update failed health checks. Container '${target}' was rolled back."
        return 0
    else
        log_error "Failed to restart previous container!"
        return 1
    fi
}

# Clean unused Docker images and build caches
clean_dangling_caches() {
    if [ "$AUTO_PRUNE" != "true" ]; then
        return 0
    fi

    if is_interactive_tty; then
        run_with_spinner "Cleaning up old unused images and build cache" bash -c '
            dangling=$(docker images -f "dangling=true" -q)
            if [ -n "$dangling" ]; then
                docker rmi $dangling >/dev/null 2>&1 || true
            fi
            docker image prune -f >/dev/null 2>&1 || true
            docker builder prune -f >/dev/null 2>&1 || true
        '
        log_success "Cache cleanup finished."
    else
        log_info "Cleaning up old unused images and build cache..."
        local dangling
        dangling=$(docker images -f "dangling=true" -q)
        if [ -n "$dangling" ]; then
            docker rmi $dangling >/dev/null 2>&1 || true
        fi
        docker image prune -f >/dev/null 2>&1 || true
        docker builder prune -f >/dev/null 2>&1 || true
        log_success "Cache cleanup finished."
    fi
}

# Interactive Container Selection
prompt_container_selection() {
    if [ -n "${CONTAINER_NAME}" ]; then
        return 0
    fi

    if [ ! -t 0 ]; then
        log_error "No container specified. Use --container <name> or set CONTAINER_NAME in .env"
        exit 1
    fi

    echo ""
    echo -e "  ${C_CYAN}╭── Active Containers ────────────────────────────────────────────────────────────╮${C_RESET}"
    printf "  ${C_CYAN}│${C_RESET} ${C_BOLD}%-3s  %-24s  %-24s  %-16s${C_RESET}\n" "#" "CONTAINER" "IMAGE" "STATUS"
    echo -e "  ${C_CYAN}│${C_RESET} ${C_DIM}───────────────────────────────────────────────────────────────────────────────${C_RESET}"

    local containers=()
    local i=1

    while IFS="|" read -r name status image ports; do
        [ -z "$name" ] && continue
        containers+=("$name")

        local st_icon
        if [[ "$status" =~ ^Up ]]; then
            st_icon="${C_GREEN}●${C_RESET}"
        elif [[ "$status" =~ ^Exited ]]; then
            st_icon="${C_RED}○${C_RESET}"
        else
            st_icon="${C_YELLOW}◐${C_RESET}"
        fi

        local short_status="${status%%,*}"
        printf "  ${C_CYAN}│${C_RESET} %-3d  %-24.24s  %-24.24s  %b %-16.16s\n" "$i" "$name" "$image" "$st_icon" "$short_status"
        ((i++))
    done < <(docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}|{{.Ports}}' 2>/dev/null || true)

    if [ ${#containers[@]} -eq 0 ]; then
        echo -e "  ${C_CYAN}│${C_RESET}   ${C_DIM}(No containers found on system)${C_RESET}"
    fi

    echo -e "  ${C_CYAN}│${C_RESET} ${C_DIM}───────────────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}│${C_RESET} ${C_BOLD}0${C_RESET}    Enter name manually"
    echo -e "  ${C_CYAN}│${C_RESET} ${C_BOLD}c${C_RESET}    Cancel and return"
    echo -e "  ${C_CYAN}╰────────────────────────────────────────────────────────────────────────────────╯${C_RESET}"
    echo ""

    local choice=""
    safe_read_line "  › Select container [number, name, or 'c' to cancel]: " "" choice

    if [ "$choice" = "c" ] || [ "$choice" = "C" ] || [ "$choice" = "cancel" ]; then
        log_warn "Selection cancelled."
        return 1
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#containers[@]}" ]; then
        CONTAINER_NAME="${containers[$((choice - 1))]}"
    elif [ "$choice" = "0" ]; then
        safe_read_line "  › Container name: " "" CONTAINER_NAME
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        log_error "Invalid selection number '${choice}'. Please select 1-${#containers[@]} or 0."
        return 1
    else
        CONTAINER_NAME="$choice"
    fi

    if [ -z "${CONTAINER_NAME}" ]; then
        log_error "No container selected."
        return 1
    fi

    if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        log_error "Container '${CONTAINER_NAME}' does not exist on this system."
        return 1
    fi
}

# Interactive Update Details
prompt_update_details() {
    prompt_container_selection || return 1

    if [ "${INTERACTIVE_MODE:-false}" != "true" ] || [ ! -t 0 ]; then
        return 0
    fi

    if [ -z "${IMAGE_NAME}" ]; then
        local detected_img
        detected_img=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
        safe_read_line "  › Image to deploy [default: ${detected_img:-latest}]: " "${detected_img:-latest}" IMAGE_NAME
    fi

    local input_stop=""
    safe_read_line "  › Stop wait time in seconds [default: ${STOP_TIMEOUT}]: " "${STOP_TIMEOUT}" input_stop
    [ -n "$input_stop" ] && STOP_TIMEOUT="$input_stop"

    local input_health=""
    safe_read_line "  › Health check wait time in seconds [default: ${HEALTH_TIMEOUT}]: " "${HEALTH_TIMEOUT}" input_health
    [ -n "$input_health" ] && HEALTH_TIMEOUT="$input_health"

    echo ""
    echo -e "  ${C_CYAN}╭──   Container Deployment Plan ─────────────────────────────╮${C_RESET}"
    printf "  ${C_CYAN}│${C_RESET}  Target Container : ${C_BOLD}%s${C_RESET}\n" "${CONTAINER_NAME}"
    printf "  ${C_CYAN}│${C_RESET}  Target Image     : ${C_CYAN}%s${C_RESET}\n" "${IMAGE_NAME}"
    printf "  ${C_CYAN}│${C_RESET}  Graceful Stop    : %ss\n" "${STOP_TIMEOUT}"
    printf "  ${C_CYAN}│${C_RESET}  Health Timeout   : %ss (interval: %ss)\n" "${HEALTH_TIMEOUT}" "${HEALTH_INTERVAL}"
    printf "  ${C_CYAN}│${C_RESET}  Rollback Backup  : %s%s\n" "${CONTAINER_NAME}" "${BACKUP_SUFFIX}"
    printf "  ${C_CYAN}│${C_RESET}  Auto-Prune Cache : %s\n" "${AUTO_PRUNE}"
    echo -e "  ${C_CYAN}╰─────────────────────────────────────────────────────────────╯${C_RESET}"
    echo ""
    local confirm=""
    safe_read_line "  › Start update now? [Y/n]: " "y" confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        log_warn "Update cancelled."
        return 1
    fi
}

# Render Full-Screen TUI Dashboard
render_fullscreen_dashboard() {
    clear_screen
    local running_cnt total_cnt docker_ver
    running_cnt=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    total_cnt=$(docker ps -a -q 2>/dev/null | wc -l | tr -d ' ')
    docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "detected")

    echo ""
    echo -e "  ${C_CYAN}╭─────────────────────────────────────────────────────────────────────────────╮${C_RESET}"
    echo -e "  ${C_CYAN}│${C_RESET}${C_BOLD}${C_CYAN}🐳  D O C K E R   A U T O - U P D A T E R   v 2 . 0${C_RESET}                           ${C_CYAN}│${C_RESET}"
    echo -e "  ${C_CYAN}│${C_RESET}   ${C_DIM}Zero-Downtime Safe Deployments • Health Checks • Auto-Rollback${C_RESET}            ${C_CYAN}│${C_RESET}"
    echo -e "  ${C_CYAN}╰─────────────────────────────────────────────────────────────────────────────╯${C_RESET}"
    echo -e "    ${C_DIM}Engine:${C_RESET} ${C_BOLD}Docker ${docker_ver}${C_RESET}  ${C_DIM}•${C_RESET}  ${C_GREEN}${running_cnt} active${C_RESET} ${C_DIM}/ ${total_cnt} total containers${C_RESET}  ${C_DIM}•${C_RESET}  ${C_CYAN}Full-Screen TUI Active${C_RESET}"
    echo ""
    echo -e "  ${C_CYAN}╭──   Active Containers ─────────────────────────────────────────────────────╮${C_RESET}"
    printf "  ${C_CYAN}│${C_RESET}  ${C_BOLD}%-24s  %-24s  %-18s${C_RESET}\n" "CONTAINER" "IMAGE" "STATUS"
    echo -e "  ${C_CYAN}│${C_RESET}  ${C_DIM}───────────────────────────────────────────────────────────────────────────${C_RESET}"

    local q_cnt=0
    while IFS="|" read -r name status image ports; do
        [ -z "$name" ] && continue
        local st_icon
        if [[ "$status" =~ ^Up ]]; then
            st_icon="${C_GREEN}●${C_RESET}"
        elif [[ "$status" =~ ^Exited ]]; then
            st_icon="${C_RED}○${C_RESET}"
        else
            st_icon="${C_YELLOW}◐${C_RESET}"
        fi
        local short_status="${status%%,*}"
        printf "  ${C_CYAN}│${C_RESET}  %-24.24s  %-24.24s  %b %-16.16s\n" "$name" "$image" "$st_icon" "$short_status"
        ((q_cnt++)) || true
        [ $q_cnt -ge 5 ] && break
    done < <(docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}|{{.Ports}}' 2>/dev/null || true)

    if [ $q_cnt -eq 0 ]; then
        echo -e "  ${C_CYAN}│${C_RESET}  ${C_DIM}(No active containers detected)${C_RESET}"
    elif [ $total_cnt -gt $q_cnt ]; then
        local rem=$(( total_cnt - q_cnt ))
        echo -e "  ${C_CYAN}│${C_RESET}  ${C_DIM}... and ${rem} more containers${C_RESET}"
    fi
    echo -e "  ${C_CYAN}╰─────────────────────────────────────────────────────────────────────────────╯${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}${C_CYAN}OPERATIONS & CONTROLS${C_RESET}"
    echo -e "    ${C_GREEN}[1]${C_RESET}    ${C_BOLD}Update Container${C_RESET}     ${C_DIM}Deploy new image with safety health checks${C_RESET}"
    echo -e "    ${C_CYAN}[2]${C_RESET}    ${C_BOLD}Inspect Status${C_RESET}       ${C_DIM}View deep health, IP, ports & rollback status${C_RESET}"
    echo -e "    ${C_YELLOW}[3]${C_RESET}    ${C_BOLD}Quick Rollback${C_RESET}       ${C_DIM}Immediately restore last known backup${C_RESET}"
    echo -e "    ${C_MAGENTA}[4]${C_RESET}    ${C_BOLD}Prune Cache${C_RESET}          ${C_DIM}Reclaim space from dangling images & build cache${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}${C_CYAN}DAEMONS & AUTOMATION${C_RESET}"
    echo -e "    ${C_BLUE}[5]${C_RESET}     ${C_BOLD}Watch Registry${C_RESET}       ${C_DIM}Continuously monitor registry & auto-deploy${C_RESET}"
    echo -e "    ${C_BLUE}[6]${C_RESET}    ${C_BOLD}Webhook Listener${C_RESET}     ${C_DIM}Run HTTP listener for CI/CD deployments${C_RESET}"
    echo ""
    echo -e "    ${C_DIM}[0]  Exit Application (or 'q')${C_RESET}"
    echo ""
}

do_watch_interactive() {
    local input_int=""
    safe_read_line "  › Check interval in seconds [default: ${WATCH_INTERVAL}]: " "${WATCH_INTERVAL}" input_int
    [ -n "$input_int" ] && WATCH_INTERVAL="$input_int"
    do_watch
}

do_webhook_interactive() {
    local input_port=""
    safe_read_line "  › Webhook port [default: ${WEBHOOK_PORT}]: " "${WEBHOOK_PORT}" input_port
    [ -n "$input_port" ] && WEBHOOK_PORT="$input_port"
    local input_sec=""
    safe_read_line "  › Secret token (optional) [default: ${WEBHOOK_SECRET}]: " "${WEBHOOK_SECRET}" input_sec
    [ -n "$input_sec" ] && WEBHOOK_SECRET="$input_sec"
    do_webhook
}

# Interactive Full-Screen Main Application
interactive_menu() {
    export INTERACTIVE_MODE="true"
    check_dependencies
    enter_fullscreen

    while true; do
        render_fullscreen_dashboard

        local menu_choice=""
        printf "  › Select option [0-6] or [q] to exit: "
        if ! get_menu_choice menu_choice; then
            exit_fullscreen
            echo "Bye!"
            exit 0
        fi

        case "$menu_choice" in
            1)
                clear_screen
                CONTAINER_NAME=""
                IMAGE_NAME=""
                ( prompt_update_details && do_update ) || true
                pause_and_return
                ;;
            2)
                clear_screen
                CONTAINER_NAME=""
                ( prompt_container_selection && do_status ) || true
                pause_and_return
                ;;
            3)
                clear_screen
                CONTAINER_NAME=""
                ( prompt_container_selection && do_manual_rollback ) || true
                pause_and_return
                ;;
            4)
                clear_screen
                echo ""
                ( do_prune ) || true
                pause_and_return
                ;;
            5)
                clear_screen
                CONTAINER_NAME=""
                ( prompt_container_selection && do_watch_interactive ) || true
                pause_and_return
                ;;
            6)
                clear_screen
                ( do_webhook_interactive ) || true
                pause_and_return
                ;;
            0|[Qq]|[Qq][Uu][Ii][Tt])
                exit_fullscreen
                echo "Bye!"
                exit 0
                ;;
            *)
                echo -e "  ${I_ERR} Invalid option. Please select 0-6 or 'q'."
                sleep 1
                ;;
        esac
    done
}

# Update Workflow
do_update() {
    check_dependencies
    prompt_update_details

    log_step "Updating container: ${CONTAINER_NAME}"

    if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        log_error "Container '${CONTAINER_NAME}' does not exist."
        exit 1
    fi

    local current_image_ref
    current_image_ref=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NAME}")
    if [ -z "${IMAGE_NAME}" ]; then
        IMAGE_NAME="${current_image_ref}"
        log_info "Using container image: ${IMAGE_NAME}"
    fi

    local backup_target="${CONTAINER_NAME}${BACKUP_SUFFIX}"

    # Check for Docker Compose
    local is_compose="false"
    local compose_file compose_service
    compose_file=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "${CONTAINER_NAME}" 2>/dev/null || true)
    compose_service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "${CONTAINER_NAME}" 2>/dev/null || true)

    if [ -n "$compose_file" ] && [ -n "$compose_service" ] && [ -f "$compose_file" ]; then
        is_compose="true"
        log_info "Detected Docker Compose service: ${compose_service}"
    fi

    local old_image_id
    old_image_id=$(docker inspect --format '{{.Image}}' "${CONTAINER_NAME}")

    # Pull image
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[dry-run] Would pull image: ${IMAGE_NAME}"
    elif [ "${SKIP_PULL:-false}" = "true" ]; then
        log_info "Skipping pull (local mode)."
    else
        if ! run_with_spinner "Pulling latest image: ${IMAGE_NAME}" docker pull "${IMAGE_NAME}"; then
            log_error "Could not pull image '${IMAGE_NAME}'. Container was not changed."
            exit 1
        fi
    fi

    local new_image_id
    new_image_id=$(docker inspect --format '{{.Id}}' "${IMAGE_NAME}" 2>/dev/null || echo "")

    # Compare versions
    if [ "${old_image_id}" = "${new_image_id}" ] && [ "${FORCE_UPDATE}" != "true" ]; then
        log_success "Image '${IMAGE_NAME}' is already up to date. Nothing to do."
        exit 0
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[dry-run] Done check. Stopping here."
        exit 0
    fi

    # Clean old backup if one exists
    if docker inspect "${backup_target}" >/dev/null 2>&1; then
        docker rm -f "${backup_target}" >/dev/null 2>&1 || true
    fi

    # Save run arguments
    local run_args_json="[]"
    if [ "$is_compose" != "true" ]; then
        run_args_json=$(generate_run_args "${CONTAINER_NAME}" "${IMAGE_NAME}")
    fi

    # Stop current container safely
    stop_container_gracefully "${CONTAINER_NAME}" "${STOP_TIMEOUT}"

    # Save backup container
    log_info "Saving backup as ${backup_target}..."
    docker rename "${CONTAINER_NAME}" "${backup_target}"

    # Start new container
    log_info "Starting new container..."
    local start_failed=false

    if [ "$is_compose" = "true" ]; then
        if ! docker compose -f "$compose_file" up -d --no-deps "$compose_service"; then
            start_failed=true
        fi
    else
        if command -v python3 >/dev/null 2>&1; then
            if ! python3 -c '
import subprocess, json, sys
cname = sys.argv[1]
image = sys.argv[2]
args = json.loads(sys.argv[3])
cmd = ["docker", "run", "-d", "--name", cname] + args + [image]
sys.exit(subprocess.run(cmd).returncode)
' "${CONTAINER_NAME}" "${IMAGE_NAME}" "${run_args_json}"; then
                start_failed=true
            fi
        else
            local cli_flags=()
            while IFS= read -r flag; do
                [ -n "$flag" ] && cli_flags+=("$flag")
            done < <(echo "$run_args_json" | jq -r '.[]')
            if ! docker run -d --name "${CONTAINER_NAME}" "${cli_flags[@]}" "${IMAGE_NAME}"; then
                start_failed=true
            fi
        fi
    fi

    if [ "$start_failed" = "true" ]; then
        log_error "Could not start new container."
        rollback_container "${CONTAINER_NAME}"
        exit 1
    fi

    # Verify health
    if ! verify_container_health "${CONTAINER_NAME}" "${HEALTH_TIMEOUT}" "${HEALTH_INTERVAL}" "${HEALTH_URL}" "${HEALTH_CMD}"; then
        rollback_container "${CONTAINER_NAME}"
        exit 1
    fi

    # Remove temporary backup
    if docker inspect "${backup_target}" >/dev/null 2>&1; then
        debug "Removing temporary backup container..."
        docker rm -f "${backup_target}" >/dev/null 2>&1 || true
    fi

    # Cleanup caches
    clean_dangling_caches

    send_notification "SUCCESS" "Container '${CONTAINER_NAME}' updated successfully to '${IMAGE_NAME}'."
    log_success "Update complete! Container '${CONTAINER_NAME}' is ready."
}

# Manual Rollback
do_manual_rollback() {
    check_dependencies
    prompt_container_selection
    rollback_container "${CONTAINER_NAME}"
}

# Continuous Watch Mode
do_watch() {
    check_dependencies
    prompt_container_selection

    echo ""
    echo -e "  ${C_CYAN}╭──    Continuous Watch Active ──────────────────────────────╮${C_RESET}"
    printf "  ${C_CYAN}│${C_RESET}  Target Container : ${C_BOLD}%s${C_RESET}\n" "${CONTAINER_NAME}"
    printf "  ${C_CYAN}│${C_RESET}  Polling Interval : %ss\n" "${WATCH_INTERVAL}"
    echo -e "  ${C_CYAN}│${C_RESET}  Task             : Checking Docker registry for image updates"
    echo -e "  ${C_CYAN}│${C_RESET}  Control          : Press ${C_BOLD}Ctrl+C${C_RESET} to exit watch mode"
    echo -e "  ${C_CYAN}╰─────────────────────────────────────────────────────────────╯${C_RESET}"
    echo ""

    local cycle=1
    while true; do
        local ts
        ts="$(date '+%H:%M:%S')"
        log_step "[${ts}] Cycle #${cycle}: Checking registry for new image..."
        ( do_update ) || {
            log_warn "Check returned error or rolled back."
        }
        ((cycle++))

        if is_interactive_tty; then
            for (( w=WATCH_INTERVAL; w>0; w-- )); do
                local frame="${SPIN_CHARS[$(( (WATCH_INTERVAL - w) % ${#SPIN_CHARS[@]} ))]}"
                printf "\r  ${C_CYAN}%s${C_RESET} Next check in ${C_BOLD}%ds${C_RESET}... ${C_DIM}(Ctrl+C to stop)${C_RESET}\033[K" "$frame" "$w"
                sleep 1
            done
            printf "\r\033[K"
        else
            sleep "${WATCH_INTERVAL}"
        fi
    done
}

# Lightweight Webhook Listener
do_webhook() {
    check_dependencies
    echo ""
    echo -e "  ${C_CYAN}╭──   Docker Webhook Server Online ──────────────────────────╮${C_RESET}"
    printf "  ${C_CYAN}│${C_RESET}  Endpoint : ${C_BOLD}${C_CYAN}http://0.0.0.0:%s/webhook${C_RESET}\n" "${WEBHOOK_PORT}"
    if [ -n "${WEBHOOK_SECRET}" ]; then
        echo -e "  ${C_CYAN}│${C_RESET}  Security : ${C_GREEN} Protected by secret token${C_RESET}"
    else
        echo -e "  ${C_CYAN}│${C_RESET}  Security : ${C_YELLOW}▲ Open endpoint (no secret configured)${C_RESET}"
    fi
    echo -e "  ${C_CYAN}│${C_RESET}  Control  : Press ${C_BOLD}Ctrl+C${C_RESET} to terminate listener"
    echo -e "  ${C_CYAN}╰─────────────────────────────────────────────────────────────╯${C_RESET}"
    echo ""

    python3 -c '
import http.server, socketserver, subprocess, os, json, sys

port = int(os.environ.get("WEBHOOK_PORT", 9000))
secret = os.environ.get("WEBHOOK_SECRET", "")
script_path = os.path.abspath(sys.argv[1])

class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        auth_header = self.headers.get("X-Webhook-Secret", "")
        if secret and auth_header != secret and not self.path.endswith("token=" + secret):
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b"{\"error\":\"Unauthorized\"}\n")
            return

        content_len = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_len) if content_len > 0 else b""
        payload = {}
        if body:
            try:
                payload = json.loads(body.decode("utf-8"))
            except Exception:
                pass

        container = payload.get("container") or os.environ.get("CONTAINER_NAME", "")
        image = payload.get("image") or os.environ.get("IMAGE_NAME", "")

        print(f"[webhook] Received update trigger for container: {container}")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{\"status\":\"ok\",\"message\":\"Update started\"}\n")

        cmd = [script_path, "update"]
        if container:
            cmd.extend(["--container", container])
        if image:
            cmd.extend(["--image", image])

        subprocess.Popen(cmd)

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{\"status\":\"ok\",\"service\":\"docker-auto-updater\"}\n")

    def log_message(self, format, *args):
        print(f"[http] {self.address_string()} - {format%args}")

with socketserver.TCPServer(("", port), WebhookHandler) as httpd:
    print(f"  Endpoint: http://0.0.0.0:{port}/webhook")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping webhook server.")
' "$0"
}

# Container Status
do_status() {
    check_dependencies
    prompt_container_selection

    if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        log_error "Container '${CONTAINER_NAME}' does not exist."
        exit 1
    fi

    local st_running st_status st_health st_image st_ip st_ports st_restart
    st_running=$(docker inspect --format '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
    st_status=$(docker inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
    st_health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CONTAINER_NAME}" 2>/dev/null || echo "none")
    st_image=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
    st_ip=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${CONTAINER_NAME}" 2>/dev/null | xargs || echo "none")
    st_ports=$(docker inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{$p}}->{{(index $conf 0).HostPort}} {{end}}' "${CONTAINER_NAME}" 2>/dev/null | xargs || echo "none")
    st_restart=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "${CONTAINER_NAME}" 2>/dev/null || echo "no")
    [ -z "$st_restart" ] && st_restart="no"
    [ -z "$st_ports" ] && st_ports="(none exposed)"

    local status_badge
    if [ "$st_running" = "true" ]; then
        status_badge="${C_GREEN}● RUNNING${C_RESET} (${st_status})"
    else
        status_badge="${C_RED}○ STOPPED${C_RESET} (${st_status})"
    fi

    local health_badge
    if [ "$st_health" = "healthy" ]; then
        health_badge="${C_GREEN}✔ HEALTHY${C_RESET} (passing checks)"
    elif [ "$st_health" = "unhealthy" ]; then
        health_badge="${C_RED}✖ UNHEALTHY${C_RESET} (failing checks)"
    elif [ "$st_health" = "starting" ]; then
        health_badge="${C_YELLOW}  STARTING${C_RESET} (awaiting health)"
    else
        health_badge="${C_DIM}None configured${C_RESET}"
    fi

    local backup_target="${CONTAINER_NAME}${BACKUP_SUFFIX}"
    local backup_info="${C_DIM}No backup active${C_RESET}"
    if docker inspect "${backup_target}" >/dev/null 2>&1; then
        backup_info="${C_GREEN}   Backup container exists (${backup_target})${C_RESET}"
    fi

    echo ""
    echo -e "  ${C_CYAN}╭──  Container Status: ${CONTAINER_NAME} ──────────────────────────────────────╮${C_RESET}"
    printf "  ${C_CYAN}│${C_RESET}  %-14s : %b\n" "State" "$status_badge"
    printf "  ${C_CYAN}│${C_RESET}  %-14s : %b\n" "Health" "$health_badge"
    printf "  ${C_CYAN}│${C_RESET}  %-14s : %s\n" "Image" "$st_image"
    printf "  ${C_CYAN}│${C_RESET}  %-14s : %s\n" "IP Address" "${st_ip:-bridge}"
    printf "  ${C_CYAN}│${C_RESET}  %-14s : %s\n" "Port Mapping" "$st_ports"
    printf "  ${C_CYAN}│${C_RESET}  %-14s : %s\n" "Restart Policy" "$st_restart"
    printf "  ${C_CYAN}│${C_RESET}  %-14s : %b\n" "Rollback State" "$backup_info"
    echo -e "  ${C_CYAN}╰───────────────────────────────────────────────────────────────────────────────╯${C_RESET}"
    echo ""
}

# Clean Command
do_prune() {
    check_dependencies
    clean_dangling_caches
}

# Help Menu
show_help() {
    echo ""
    show_banner
    echo -e "
${C_BOLD}Usage:${C_RESET}
  $(basename "$0") [command] [options]

${C_BOLD}${C_CYAN}Commands:${C_RESET}
  ${C_BOLD}update${C_RESET}       Update a container (pull, safe stop, health check, rollback on fail) [default]
  ${C_BOLD}rollback${C_RESET}     Restore container to previous working backup
  ${C_BOLD}watch${C_RESET}        Continuously poll registry and update automatically on new image
  ${C_BOLD}webhook${C_RESET}      Run a lightweight webhook HTTP listener
  ${C_BOLD}status${C_RESET}       Show container status, health, ports, and backup state
  ${C_BOLD}prune${C_RESET}        Clean up unused Docker images and build cache
  ${C_BOLD}help${C_RESET}         Show this help screen

${C_BOLD}${C_CYAN}Options:${C_RESET}
  -c, --container <name>     Container name (required for automated runs)
  -i, --image <name:tag>     Image to deploy (default: container's current image)
  -t, --stop-timeout <secs>  Safe stop wait time in seconds (default: 15)
  --health-timeout <secs>    Health check wait time in seconds (default: 60)
  --health-interval <secs>   Time between health checks in seconds (default: 3)
  --health-url <url>         Custom HTTP check URL (e.g. http://localhost:8080/health)
  --health-cmd <cmd>         Custom shell command to check health
  --force                    Force re-deployment even if image did not change
  --interactive              Show interactive prompts
  --no-prune                 Do not clean up unused cache after update
  --no-animation             Disable live spinners and progress animations
  --no-color                 Disable ANSI color output
  --dry-run                  Preview steps without changing anything
  -v, --verbose              Show debug logs
  -h, --help                 Show this help screen

${C_BOLD}${C_CYAN}Examples:${C_RESET}
  $(basename "$0")                              # Opens interactive dashboard
  $(basename "$0") update -c my-web-app         # Direct container update
  $(basename "$0") status -c my-web-app         # View container health card
  $(basename "$0") rollback -c my-web-app       # Roll back to last backup
  $(basename "$0") prune                        # Clean Docker cache
"
}

# Entrypoint
main() {
    load_config

    if [ $# -eq 0 ] && [ -t 0 ]; then
        interactive_menu
        exit 0
    fi

    if [ $# -gt 0 ] && [[ "$1" =~ ^(menu|dashboard|interactive|tui)$ ]]; then
        interactive_menu
        exit 0
    fi

    local command="update"
    if [ $# -gt 0 ] && [[ "$1" =~ ^(update|rollback|watch|webhook|status|prune|help|-h|--help)$ ]]; then
        command="$1"
        shift
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--container)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            -i|--image)
                IMAGE_NAME="$2"
                shift 2
                ;;
            -t|--stop-timeout)
                STOP_TIMEOUT="$2"
                shift 2
                ;;
            --health-timeout)
                HEALTH_TIMEOUT="$2"
                shift 2
                ;;
            --health-interval)
                HEALTH_INTERVAL="$2"
                shift 2
                ;;
            --health-url)
                HEALTH_URL="$2"
                shift 2
                ;;
            --health-cmd)
                HEALTH_CMD="$2"
                shift 2
                ;;
            --no-prune)
                AUTO_PRUNE="false"
                shift
                ;;
            --force)
                FORCE_UPDATE="true"
                shift
                ;;
            --skip-pull)
                SKIP_PULL="true"
                shift
                ;;
            --interactive)
                INTERACTIVE_MODE="true"
                shift
                ;;
            --interval)
                WATCH_INTERVAL="$2"
                shift 2
                ;;
            --port)
                WEBHOOK_PORT="$2"
                shift 2
                ;;
            --secret)
                WEBHOOK_SECRET="$2"
                shift 2
                ;;
            --config)
                CONFIG_FILE="$2"
                load_config
                shift 2
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --no-animation)
                NO_ANIMATION="true"
                shift
                ;;
            --no-color)
                NO_COLOR="true"
                init_colors
                shift
                ;;
            -v|--verbose)
                VERBOSE="true"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [ "${INTERACTIVE_MODE:-false}" = "true" ] && [ -z "${CONTAINER_NAME:-}" ]; then
        interactive_menu
        exit 0
    fi

    case "$command" in
        update)
            do_update
            ;;
        rollback)
            do_manual_rollback
            ;;
        watch)
            do_watch
            ;;
        webhook)
            do_webhook
            ;;
        status)
            do_status
            ;;
        prune)
            do_prune
            ;;
        help|-h|--help)
            show_help
            ;;
    esac
}

main "$@"
