#!/usr/bin/env bash
# Docker Container Auto-Updater & CI/CD Deployment Script
# ------------------------------------------------------------------------------
# Automatically checks for, pulls, and rolls out container image updates with:
#  - Graceful container shutdown
#  - Zero-data-loss rollback target preservation
#  - Docker native & HTTP health check validation
#  - Automatic, lossless rollback upon health failure or crash
#  - Dangling Docker image and build cache cleanup
#  - Registry watcher and lightweight HTTP webhook trigger modes

set -Eeuo pipefail

# Script directory and default paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/.env}"

# Default Configuration
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
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
LOG_FILE="${LOG_FILE:-}"

# Terminal Colors
C_RESET="\033[0m"
C_RED="\033[1;31m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[1;34m"
C_PURPLE="\033[1;35m"
C_CYAN="\033[1;36m"
C_BOLD="\033[1m"

# Logging Utilities
_log() {
    local level_color="$1"
    local level_label="$2"
    shift 2
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local message="$*"
    local formatted_msg="[${timestamp}] [${level_label}] ${message}"

    if [ -t 1 ]; then
        echo -e "${level_color}${formatted_msg}${C_RESET}"
    else
        echo -e "${formatted_msg}"
    fi

    if [ -n "${LOG_FILE:-}" ]; then
        echo "[${timestamp}] [${level_label}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

log_info()    { _log "${C_CYAN}" "INFO" "$@"; }
log_step()    { _log "${C_PURPLE}" "STEP" "$@"; }
log_success() { _log "${C_GREEN}" "SUCCESS" "$@"; }
log_warn()    { _log "${C_YELLOW}" "WARN" "$@"; }
log_error()   { _log "${C_RED}" "ERROR" "$@"; }

debug() {
    if [ "${VERBOSE}" = "true" ]; then
        _log "${C_BLUE}" "DEBUG" "$@"
    fi
}

# Notification Helper (Slack / Discord)
send_notification() {
    local status="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Discord webhook
    if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
        local color_dec=3066993 # Green
        [ "$status" = "ROLLBACK" ] && color_dec=15158332 # Red
        [ "$status" = "WARN" ] && color_dec=15105570 # Yellow

        local payload
        payload=$(jq -n \
            --arg title "Docker Deployment Alert: ${status}" \
            --arg desc "${message}" \
            --arg footer "Container: ${CONTAINER_NAME:-unknown} | ${timestamp}" \
            --argjson color "${color_dec}" \
            '{embeds: [{title: $title, description: $desc, color: $color, footer: {text: $footer}}]}')
        curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
    fi

    # Slack webhook
    if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
        local icon=":white_check_mark:"
        [ "$status" = "ROLLBACK" ] && icon=":rotating_light:"
        [ "$status" = "WARN" ] && icon=":warning:"
        local payload
        payload=$(jq -n --arg text "${icon} *Docker Auto-Updater (${status})*: ${message}" '{"text": $text}')
        curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
}

# Dependency & Preflight Checks
check_dependencies() {
    local missing=()
    for cmd in docker jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required command-line dependencies: ${missing[*]}"
        log_error "Please install them before running this script (e.g., sudo apt-get install -y jq docker.io)."
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        log_error "Cannot connect to the Docker daemon. Is Docker running and does the current user have permissions to access /var/run/docker.sock?"
        exit 1
    fi
}

# Load Configuration File
load_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        debug "Loading environment configuration from: ${CONFIG_FILE}"
        # Export vars from .env without overwriting variables passed explicitly
        while IFS='=' read -r key value || [ -n "$key" ]; do
            # Trim whitespace and comments
            key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -z "$key" || "$key" =~ ^# ]]; then
                continue
            fi
            value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//")
            # If variable is not already defined in env, set it
            if [ -z "${!key:-}" ]; then
                export "$key"="$value"
            fi
        done < "${CONFIG_FILE}"
    fi
}

# Extract Container Inspect Specifications for Standalone docker run
generate_run_args() {
    local inspect_target="$1"
    local target_image="$2"

    # Python-based generator produces clean arguments safely
    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import subprocess, json, sys

target = sys.argv[1]
image = sys.argv[2]
try:
    raw = subprocess.check_output(["docker", "inspect", target], stderr=subprocess.DEVNULL)
    data = json.loads(raw)[0]
except Exception as e:
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
if networks and networks[0] != "bridge" and networks[0] != "default":
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

# Volume binds
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

# Labels (preserve non-compose labels)
labels = cfg.get("Labels") or {}
for k, v in labels.items():
    if not k.startswith("com.docker.compose."):
        args.append(f"--label={k}={v}")

# Write as JSON array for bash consumption
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

# Graceful Stop Container
stop_container_gracefully() {
    local target="$1"
    local timeout="${2:-15}"

    if ! docker inspect "$target" >/dev/null 2>&1; then
        return 0
    fi

    local is_running
    is_running=$(docker inspect --format '{{.State.Running}}' "$target" 2>/dev/null || echo "false")
    if [ "$is_running" = "true" ]; then
        log_step "Gracefully stopping container '${target}' (timeout: ${timeout}s)..."
        docker stop -t "$timeout" "$target" >/dev/null
        log_success "Container '${target}' stopped gracefully."
    else
        debug "Container '${target}' is already stopped."
    fi
}

# Health Verification
verify_container_health() {
    local target="$1"
    local timeout="${2:-60}"
    local interval="${3:-3}"
    local health_url="${4:-}"
    local health_cmd="${5:-}"

    log_step "Verifying container health check status for '${target}' (max wait: ${timeout}s)..."

    local elapsed=0
    local start_time
    start_time=$(date +%s)
    local observed_stable_seconds=0
    local min_stable_required=8

    while [ "$elapsed" -lt "$timeout" ]; do
        # 1. Check if container is still running
        local is_running exit_code
        is_running=$(docker inspect --format '{{.State.Running}}' "$target" 2>/dev/null || echo "false")
        exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$target" 2>/dev/null || echo "-1")

        if [ "$is_running" != "true" ]; then
            log_error "Container '${target}' died unexpectedly! Exit code: ${exit_code}"
            return 1
        fi

        # 2. Check Docker Native Health Status
        local health_status
        health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$target" 2>/dev/null || echo "none")

        if [ "$health_status" = "healthy" ]; then
            log_success "Native Docker health check confirmed HEALTHY! (after ${elapsed}s)"
            return 0
        elif [ "$health_status" = "unhealthy" ]; then
            log_error "Native Docker health check reported UNHEALTHY!"
            local log_entries
            log_entries=$(docker inspect --format '{{range .State.Health.Log}}{{.Output}}{{end}}' "$target" 2>/dev/null || true)
            if [ -n "$log_entries" ]; then
                log_error "Health check failure log: ${log_entries}"
            fi
            return 1
        elif [ "$health_status" = "starting" ]; then
            log_info "Health check status is 'starting'... (${elapsed}s / ${timeout}s elapsed)"
        elif [ "$health_status" = "none" ]; then
            # No native HEALTHCHECK configured in image
            if [ -n "$health_url" ]; then
                debug "Checking custom HTTP health URL: ${health_url}"
                if curl -s -f -m 3 "$health_url" >/dev/null 2>&1; then
                    log_success "HTTP health check to '${health_url}' succeeded with HTTP 200 OK!"
                    return 0
                else
                    debug "HTTP endpoint '${health_url}' not ready yet."
                fi
            elif [ -n "$health_cmd" ]; then
                debug "Executing custom health check command: ${health_cmd}"
                if eval "$health_cmd" >/dev/null 2>&1; then
                    log_success "Custom health command '${health_cmd}' succeeded!"
                    return 0
                fi
            else
                # Fallback: Stability observation window
                observed_stable_seconds=$((observed_stable_seconds + interval))
                debug "No health check specified. Observing runtime stability: ${observed_stable_seconds}s / ${min_stable_required}s"
                if [ "$observed_stable_seconds" -ge "$min_stable_required" ]; then
                    log_success "Container has remained active and stable for ${observed_stable_seconds}s without crashes."
                    return 0
                fi
            fi
        fi

        sleep "$interval"
        local now
        now=$(date +%s)
        elapsed=$((now - start_time))
    done

    log_error "Health check timed out after ${timeout} seconds without becoming healthy!"
    return 1
}

# Automatic Rollback
rollback_container() {
    local target="$1"
    local backup_target="${target}${BACKUP_SUFFIX}"

    log_warn "-----------------------------------------------------------------"
    log_warn "  FAILURE DETECTED - INITIATING AUTOMATIC CONTAINER ROLLBACK"
    log_warn "-----------------------------------------------------------------"

    # Print logs from failed container to diagnose issues
    if docker inspect "$target" >/dev/null 2>&1; then
        log_warn "Dumping last 40 lines of logs from failing container '${target}':"
        echo -e "${C_YELLOW}----------------------- CONTAINER LOG DUMP -----------------------${C_RESET}"
        docker logs --tail 40 "$target" 2>&1 || true
        echo -e "${C_YELLOW}------------------------------------------------------------------${C_RESET}"

        log_step "Terminating and removing broken container '${target}'..."
        docker rm -f "$target" >/dev/null 2>&1 || true
    fi

    # Check if backup container exists
    if ! docker inspect "$backup_target" >/dev/null 2>&1; then
        log_error "Fatal: Rollback target container '${backup_target}' not found! Cannot automatically restore."
        send_notification "ROLLBACK" "Failed deployment of '${target}', and no rollback target '${backup_target}' was available."
        return 1
    fi

    log_step "Restoring backup container '${backup_target}' back to '${target}'..."
    docker rename "$backup_target" "$target"
    docker start "$target" >/dev/null

    # Confirm restored container is running
    local restored_running
    restored_running=$(docker inspect --format '{{.State.Running}}' "$target" 2>/dev/null || echo "false")

    if [ "$restored_running" = "true" ]; then
        log_success "Automatic rollback COMPLETED. Container '${target}' is safely back online."
        send_notification "ROLLBACK" "Update failed health verification. Container '${target}' was automatically rolled back to the previous stable version."
        return 0
    else
        log_error "CRITICAL: Restored container '${target}' failed to restart!"
        return 1
    fi
}

# Clean Dangling Docker Caches
clean_dangling_caches() {
    if [ "$AUTO_PRUNE" != "true" ]; then
        log_info "Cache cleanup skipped (AUTO_PRUNE is false)."
        return 0
    fi

    log_step "Cleaning dangling Docker images and build caches..."

    # Prune untagged / dangling images (<none>)
    local dangling_images
    dangling_images=$(docker images -f "dangling=true" -q)
    if [ -n "$dangling_images" ]; then
        log_info "Removing dangling image layers..."
        docker rmi $dangling_images >/dev/null 2>&1 || true
    fi
    docker image prune -f >/dev/null 2>&1 || true

    # Prune dangling builder cache
    log_info "Pruning Docker build cache..."
    docker builder prune -f >/dev/null 2>&1 || true

    log_success "Dangling Docker caches and images pruned successfully."
}

# ------------------------------------------------------------------------------
# Interactive User Input Prompts (Terminal Mode)
# ------------------------------------------------------------------------------
prompt_container_selection() {
    if [ -n "${CONTAINER_NAME}" ]; then
        return 0
    fi

    # Check if running in an interactive terminal
    if [ ! -t 0 ]; then
        log_error "No container specified! Use --container <name> or set CONTAINER_NAME in .env"
        exit 1
    fi

    echo -e "\n${C_BOLD}Active Containers on this host:${C_RESET}"
    local containers=()
    local i=1

    while IFS=$'\t' read -r name status image; do
        if [ -n "$name" ]; then
            containers+=("$name")
            printf "  [%2d] %-30s %-25s (%s)\n" "$i" "$name" "$image" "$status"
            ((i++))
        fi
    done < <(docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true)

    if [ ${#containers[@]} -eq 0 ]; then
        echo "  (No existing containers found)"
    fi
    echo "  [ 0] Enter custom container name manually"
    echo ""

    local choice
    read -r -p "Piliin ang container [Number o Name]: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#containers[@]}" ]; then
        CONTAINER_NAME="${containers[$((choice - 1))]}"
    elif [ "$choice" = "0" ] || [ -z "$choice" ]; then
        read -r -p "I-type ang pangalan ng container: " CONTAINER_NAME
    else
        CONTAINER_NAME="$choice"
    fi

    if [ -z "${CONTAINER_NAME}" ]; then
        log_error "Walang container na napili. Kinakansela ang operasyon."
        exit 1
    fi
}

prompt_update_details() {
    prompt_container_selection

    # Only prompt for further parameters if interactive mode was explicitly requested or in interactive menu
    if [ "${INTERACTIVE_MODE:-false}" != "true" ] || [ ! -t 0 ]; then
        return 0
    fi

    # Auto-detect image from container if not set
    if [ -z "${IMAGE_NAME}" ]; then
        local detected_img
        detected_img=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
        read -r -p "Docker Image to deploy [default: ${detected_img:-latest}]: " input_img
        IMAGE_NAME="${input_img:-$detected_img}"
    fi

    read -r -p "Graceful stop timeout in seconds [default: ${STOP_TIMEOUT}]: " input_stop
    if [ -n "$input_stop" ]; then
        STOP_TIMEOUT="$input_stop"
    fi

    read -r -p "Health check timeout in seconds [default: ${HEALTH_TIMEOUT}]: " input_health
    if [ -n "$input_health" ]; then
        HEALTH_TIMEOUT="$input_health"
    fi

    echo ""
    echo -e "${C_CYAN}Summary ng Deployment:${C_RESET}"
    echo "  Target Container : ${CONTAINER_NAME}"
    echo "  Target Image     : ${IMAGE_NAME}"
    echo "  Stop Timeout     : ${STOP_TIMEOUT}s"
    echo "  Health Timeout   : ${HEALTH_TIMEOUT}s"
    echo ""
    read -r -p "Ituloy ang update? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        log_warn "Kinansela ng user ang deployment."
        exit 0
    fi
}

interactive_menu() {
    export INTERACTIVE_MODE="true"
    echo -e "\n${C_BOLD}=====================================================${C_RESET}"
    echo -e "${C_BOLD}  🐳 Docker Container Auto-Updater & Deployment Menu ${C_RESET}"
    echo -e "${C_BOLD}=====================================================${C_RESET}"
    echo "  1) Update a container (Graceful Stop, Pull, Health Check, Auto-Rollback)"
    echo "  2) Check container status & health"
    echo "  3) Roll back container to previous backup"
    echo "  4) Prune dangling Docker caches & untagged images"
    echo "  5) Start continuous registry watcher (auto-update on push)"
    echo "  6) Start HTTP webhook listener daemon"
    echo "  7) Exit"
    echo ""
    read -r -p "Piliin ang aksyon [1-7]: " menu_choice

    case "$menu_choice" in
        1)
            prompt_update_details
            do_update
            ;;
        2)
            prompt_container_selection
            do_status
            ;;
        3)
            prompt_container_selection
            do_manual_rollback
            ;;
        4)
            do_prune
            ;;
        5)
            prompt_container_selection
            read -r -p "Polling interval in seconds [default: ${WATCH_INTERVAL}]: " input_int
            [ -n "$input_int" ] && WATCH_INTERVAL="$input_int"
            do_watch
            ;;
        6)
            read -r -p "Webhook port [default: ${WEBHOOK_PORT}]: " input_port
            [ -n "$input_port" ] && WEBHOOK_PORT="$input_port"
            read -r -p "Webhook secret token (optional) [default: ${WEBHOOK_SECRET}]: " input_sec
            [ -n "$input_sec" ] && WEBHOOK_SECRET="$input_sec"
            do_webhook
            ;;
        7)
            echo "Salamat at paalam!"
            exit 0
            ;;
        *)
            log_error "Hindi wastong pagpipilian."
            exit 1
            ;;
    esac
}

# Core Update Workflow
do_update() {
    check_dependencies
    prompt_update_details

    log_step "Initializing deployment workflow for container: ${C_BOLD}${CONTAINER_NAME}${C_RESET}"

    # Verify target container exists
    if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        log_error "Container '${CONTAINER_NAME}' does not exist on this Docker host."
        exit 1
    fi

    # Determine image name if not explicitly set
    local current_image_ref
    current_image_ref=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NAME}")
    if [ -z "${IMAGE_NAME}" ]; then
        IMAGE_NAME="${current_image_ref}"
        log_info "Auto-detected image from container: ${IMAGE_NAME}"
    fi

    local backup_target="${CONTAINER_NAME}${BACKUP_SUFFIX}"

    # Check for Docker Compose metadata
    local is_compose="false"
    local compose_file=""
    local compose_service=""
    local compose_workdir=""

    compose_file=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "${CONTAINER_NAME}" 2>/dev/null || true)
    compose_service=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "${CONTAINER_NAME}" 2>/dev/null || true)
    compose_workdir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "${CONTAINER_NAME}" 2>/dev/null || true)

    if [ -n "$compose_file" ] && [ -n "$compose_service" ] && [ -f "$compose_file" ]; then
        is_compose="true"
        log_info "Detected Docker Compose deployment (service: ${compose_service}, file: ${compose_file})"
    fi

    # Get current running image ID/digest
    local old_image_id
    old_image_id=$(docker inspect --format '{{.Image}}' "${CONTAINER_NAME}")
    debug "Current container image ID: ${old_image_id}"

    # Pull the latest image
    log_step "Pulling latest image: ${C_BOLD}${IMAGE_NAME}${C_RESET}..."
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would pull image: ${IMAGE_NAME}"
    elif [ "${SKIP_PULL:-false}" = "true" ]; then
        log_info "Skipping registry pull (SKIP_PULL=true / local test mode)."
    else
        if ! docker pull "${IMAGE_NAME}"; then
            log_error "Failed to pull image '${IMAGE_NAME}' from registry. Deployment aborted; current container remains untouched."
            exit 1
        fi
    fi

    # Get newly pulled image ID
    local new_image_id
    new_image_id=$(docker inspect --format '{{.Id}}' "${IMAGE_NAME}" 2>/dev/null || echo "")
    debug "Pulled image ID: ${new_image_id}"

    # Check if image ID actually changed
    if [ "${old_image_id}" = "${new_image_id}" ] && [ "${FORCE_UPDATE}" != "true" ]; then
        log_success "Image '${IMAGE_NAME}' is already up-to-date (${new_image_id:0:19}). No changes detected."
        log_info "Use --force or FORCE_UPDATE=true to force re-creation."
        exit 0
    fi

    log_info "New image version detected! Proceeding with zero-downtime transition."

    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Completed check. Stopping here because DRY_RUN=true."
        exit 0
    fi

    # 1. Clean up any leftover old backup container
    if docker inspect "${backup_target}" >/dev/null 2>&1; then
        debug "Removing stale backup container '${backup_target}'..."
        docker rm -f "${backup_target}" >/dev/null 2>&1 || true
    fi

    # 2. Extract configuration arguments before stopping if standalone
    local run_args_json="[]"
    if [ "$is_compose" != "true" ]; then
        debug "Extracting container configuration parameters via inspect..."
        run_args_json=$(generate_run_args "${CONTAINER_NAME}" "${IMAGE_NAME}")
    fi

    # 3. Gracefully stop current container
    stop_container_gracefully "${CONTAINER_NAME}" "${STOP_TIMEOUT}"

    # 4. Rename to backup target (instant, zero-data-loss rollback safety net)
    log_step "Preserving current container as rollback target: ${backup_target}..."
    docker rename "${CONTAINER_NAME}" "${backup_target}"

    # 5. Launch new container
    log_step "Launching updated container '${CONTAINER_NAME}'..."
    local start_failed=false

    if [ "$is_compose" = "true" ]; then
        log_info "Recreating container via Docker Compose..."
        if ! docker compose -f "$compose_file" up -d --no-deps "$compose_service"; then
            start_failed=true
        fi
    else
        # Launch standalone container using extracted parameters
        if command -v python3 >/dev/null 2>&1; then
            # Run using python helper for robust arg unpacking
            if ! python3 -c '
import subprocess, json, sys

cname = sys.argv[1]
image = sys.argv[2]
args_json = sys.argv[3]

args = json.loads(args_json)
cmd = ["docker", "run", "-d", "--name", cname] + args + [image]
res = subprocess.run(cmd)
sys.exit(res.returncode)
' "${CONTAINER_NAME}" "${IMAGE_NAME}" "${run_args_json}"; then
                start_failed=true
            fi
        else
            # Shell loop fallback
            local cli_flags=()
            while IFS= read -r flag; do
                [ -n "$flag" ] && cli_flags+=("$flag")
            done < <(echo "$run_args_json" | jq -r '.[]')
            if ! docker run -d --name "${CONTAINER_NAME}" "${cli_flags[@]}" "${IMAGE_NAME}"; then
                start_failed=true
            fi
        fi
    fi

    # If container failed to even launch, trigger rollback immediately
    if [ "$start_failed" = "true" ]; then
        log_error "Failed to launch new container from image '${IMAGE_NAME}'!"
        rollback_container "${CONTAINER_NAME}"
        exit 1
    fi

    log_success "New container '${CONTAINER_NAME}' created."

    # 6. Verify Health Check Status
    if ! verify_container_health "${CONTAINER_NAME}" "${HEALTH_TIMEOUT}" "${HEALTH_INTERVAL}" "${HEALTH_URL}" "${HEALTH_CMD}"; then
        # HEALTH CHECK FAILED -> AUTOMATIC ROLLBACK
        rollback_container "${CONTAINER_NAME}"
        exit 1
    fi

    # 7. SUCCESS: Health check passed!
    log_success "-----------------------------------------------------------------"
    log_success "  CONTAINER UPDATE & HEALTH VALIDATION SUCCEEDED!"
    log_success "-----------------------------------------------------------------"

    # Safe to clean up the rollback container now
    if docker inspect "${backup_target}" >/dev/null 2>&1; then
        debug "Removing temporary rollback container '${backup_target}'..."
        docker rm -f "${backup_target}" >/dev/null 2>&1 || true
    fi

    # 8. Clear out dangling Docker caches and untagged images
    clean_dangling_caches

    send_notification "SUCCESS" "Container '${CONTAINER_NAME}' successfully updated to image '${IMAGE_NAME}' and passed all health checks."
    log_success "Deployment pipeline finished with exit code 0."
}

# Manual Rollback Subcommand
do_manual_rollback() {
    check_dependencies
    prompt_container_selection
    rollback_container "${CONTAINER_NAME}"
}

# Continuous Watch / Poll Mode
do_watch() {
    check_dependencies
    prompt_container_selection

    log_info "Starting registry polling watcher for '${CONTAINER_NAME}' (interval: ${WATCH_INTERVAL}s)..."
    log_info "Press Ctrl+C to terminate."

    while true; do
        log_info "Polling registry for updates on container '${CONTAINER_NAME}'..."
        # Run update; if up to date, it exits 0 without restarting
        ( do_update ) || {
            log_warn "Update iteration reported error or rolled back."
        }
        sleep "${WATCH_INTERVAL}"
    done
}

# Lightweight Webhook Server
do_webhook() {
    check_dependencies
    log_info "Starting lightweight CI/CD Webhook receiver on port ${WEBHOOK_PORT}..."
    if [ -n "${WEBHOOK_SECRET}" ]; then
        log_info "Webhook authentication enabled (checking secret)."
    else
        log_warn "Webhook authentication disabled. Set WEBHOOK_SECRET in .env for security."
    fi

    python3 -c '
import http.server, socketserver, subprocess, os, json, sys

port = int(os.environ.get("WEBHOOK_PORT", 9000))
secret = os.environ.get("WEBHOOK_SECRET", "")
script_path = os.path.abspath(sys.argv[1])

class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        auth_header = self.headers.get("X-Webhook-Secret", "")
        # Check authorization
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

        print(f"[WEBHOOK] Trigger received for container: {container}, image: {image}")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{\"status\":\"triggered\",\"message\":\"Update initiated\"}\n")

        # Spawn update process
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
        self.wfile.write(b"{\"status\":\"healthy\",\"service\":\"docker-auto-updater-webhook\"}\n")

    def log_message(self, format, *args):
        # Clean server logs
        print(f"[HTTP] {self.address_string()} - {format%args}")

with socketserver.TCPServer(("", port), WebhookHandler) as httpd:
    print(f"[WEBHOOK] Server listening on http://0.0.0.0:{port}/webhook")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[WEBHOOK] Shutting down.")
' "$0"
}

# Container & Health Status Report
do_status() {
    check_dependencies
    prompt_container_selection

    if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
        log_error "Container '${CONTAINER_NAME}' does not exist."
        exit 1
    fi

    echo -e "${C_BOLD}Container Status Report: ${CONTAINER_NAME}${C_RESET}"
    echo "----------------------------------------------------"
    docker inspect --format '
Status:         {{.State.Status}}
Running:        {{.State.Running}}
ExitCode:       {{.State.ExitCode}}
StartedAt:      {{.State.StartedAt}}
Health Status:  {{if .State.Health}}{{.State.Health.Status}}{{else}}None configured{{end}}
Image ID:       {{.Image}}
Image Name:     {{.Config.Image}}
Restart Policy: {{.HostConfig.RestartPolicy.Name}}
Ports:          {{range $p, $conf := .NetworkSettings.Ports}}{{$p}} -> {{(index $conf 0).HostPort}} {{end}}
' "${CONTAINER_NAME}"
    echo "----------------------------------------------------"

    local backup_target="${CONTAINER_NAME}${BACKUP_SUFFIX}"
    if docker inspect "${backup_target}" >/dev/null 2>&1; then
        log_warn "A rollback backup target exists: ${backup_target}"
    fi
}

# Prune Subcommand
do_prune() {
    check_dependencies
    clean_dangling_caches
}

# Help & Usage
show_help() {
    echo -e "${C_BOLD}Docker Container Auto-Updater & CI/CD Deployment Script${C_RESET}

Usage:
  $(basename "$0") [command] [options]

Commands:
  update                Run the update pipeline (pull, stop, health-check, rollback on fail, prune) [Default]
  rollback              Manually roll back to the saved backup container
  watch                 Continuously poll registry and automatically update on digest change
  webhook               Start lightweight HTTP webhook server on specified port
  status                Show running status, health check status, and image info for container
  prune                 Clean up dangling Docker images and build caches
  help, -h, --help      Display this help menu

Options:
  -c, --container <name>      Target Docker container name (required)
  -i, --image <name:tag>      Docker image to pull (defaults to container's current image)
  -t, --stop-timeout <secs>   Graceful stop timeout in seconds before SIGKILL (default: 15)
  --health-timeout <secs>     Maximum seconds to wait for healthy status (default: 60)
  --health-interval <secs>    Seconds between health check polls (default: 3)
  --health-url <url>          Custom HTTP health check endpoint (e.g. http://localhost:8080/health)
  --health-cmd <cmd>          Custom shell command to verify health
  --no-prune                  Skip dangling cache and image cleanup
  --force                     Force re-deployment even if image digest is unchanged
  --interval <secs>           Polling interval for watch mode (default: 60)
  --port <port>               Port for webhook server (default: 9000)
  --secret <token>            Secret token for authenticating webhook requests
  --config <path>             Path to custom .env configuration file
  --dry-run                   Preview update steps without stopping or pulling
  -v, --verbose               Enable verbose debug logging

Environment Variables (can also be specified in .env):
  CONTAINER_NAME, IMAGE_NAME, STOP_TIMEOUT, HEALTH_TIMEOUT, HEALTH_INTERVAL,
  HEALTH_URL, HEALTH_CMD, AUTO_PRUNE, FORCE_UPDATE, BACKUP_SUFFIX,
  WATCH_INTERVAL, WEBHOOK_PORT, WEBHOOK_SECRET, DISCORD_WEBHOOK_URL, SLACK_WEBHOOK_URL

Examples:
  $(basename "$0") update --container my-web-app
  $(basename "$0") update -c my-web-app -i myrepo/web-app:latest --health-timeout 45
  $(basename "$0") watch -c my-web-app --interval 30
  $(basename "$0") webhook --port 9000 --secret \"super-secret-token\"
  $(basename "$0") rollback -c my-web-app
  $(basename "$0") prune
"
}

# Entry Point & CLI Parsing
main() {
    load_config

    # If called with no arguments in an interactive terminal, show interactive menu
    if [ $# -eq 0 ] && [ -t 0 ]; then
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
            --interactive)
                INTERACTIVE_MODE="true"
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
