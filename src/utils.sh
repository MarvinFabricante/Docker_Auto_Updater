#!/usr/bin/env bash
# utils.sh - Helper functions: logging, color definitions, configuration, notifications

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

# Output Functions
log_step()    { echo -e "${I_STEP} ${C_BOLD}$*${C_RESET}"; log_to_file "STEP" "$*"; }
log_success() { echo -e "${I_OK} $*"; log_to_file "OK" "$*"; }
log_info()    { echo -e "  ${I_BULLET} $*"; log_to_file "INFO" "$*"; }
log_warn()    { echo -e "${I_WARN} $*"; log_to_file "WARN" "$*"; }
log_error()   { echo -e "${I_ERR} $*"; log_to_file "ERROR" "$*"; }

debug() {
    if [ "${VERBOSE:-false}" = "true" ]; then
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
    if [ -f "${CONFIG_FILE:-}" ]; then
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

# Visual Banner
show_banner() {
    echo -e "  ${C_CYAN}╭────────────────────────────────────────────────────────────╮${C_RESET}"
    echo -e "  ${C_CYAN}│${C_RESET} ${C_BOLD}${C_CYAN}🐳  D O C K E R   A U T O - U P D A T E R   v 2 . 0${C_RESET}        ${C_CYAN}│${C_RESET}"
    echo -e "  ${C_CYAN}│${C_RESET}   ${C_DIM}Zero-Downtime Deployments • Safe Healthchecks • Rollback${C_RESET} ${C_CYAN}│${C_RESET}"
    echo -e "  ${C_CYAN}╰────────────────────────────────────────────────────────────╯${C_RESET}"
}

# Help Menu
show_help() {
    echo ""
    show_banner
    echo -e "
${C_BOLD}Usage:${C_RESET}
  $(basename "${MAIN_SCRIPT:-$0}") [command] [options]

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
  $(basename "${MAIN_SCRIPT:-$0}")                              # Opens interactive dashboard
  $(basename "${MAIN_SCRIPT:-$0}") update -c my-web-app         # Direct container update
  $(basename "${MAIN_SCRIPT:-$0}") status -c my-web-app         # View container health card
  $(basename "${MAIN_SCRIPT:-$0}") rollback -c my-web-app       # Roll back to last backup
  $(basename "${MAIN_SCRIPT:-$0}") prune                        # Clean Docker cache
"
}
