#!/usr/bin/env bash
# Docker Container Auto-Updater
# The main entry point (parses arguments, routes to modules)

set -Eeuo pipefail
shopt -s extglob 2>/dev/null || true

# Resolve script directory (handling symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
MAIN_SCRIPT="${SCRIPT_DIR}/container.sh"
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

# Source Internal Modules
source "${SCRIPT_DIR}/src/utils.sh"
source "${SCRIPT_DIR}/src/tui.sh"
source "${SCRIPT_DIR}/src/core_engine.sh"
source "${SCRIPT_DIR}/src/server.sh"

# Initialize terminal formatting
init_colors

# Main Entrypoint
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
