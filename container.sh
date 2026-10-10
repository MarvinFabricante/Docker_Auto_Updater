#!/usr/bin/env bash
# ==============================================================================
# Docker Container Auto-Updater
# A simple, safe tool to update Docker containers with auto-rollback.
# ==============================================================================

set -Eeuo pipefail

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

# Minimalist CLI Colors
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_GREEN="\033[32m"
C_RED="\033[31m"
C_YELLOW="\033[33m"
C_CYAN="\033[36m"

# Minimalist Icons
I_STEP="${C_CYAN}›${C_RESET}"
I_OK="${C_GREEN}✔${C_RESET}"
I_ERR="${C_RED}✖${C_RESET}"
I_WARN="${C_YELLOW}▲${C_RESET}"
I_BULLET="${C_DIM}•${C_RESET}"

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
        log_info "Stopping old container safely (giving it up to ${timeout}s)..."
        docker stop -t "$timeout" "$target" >/dev/null
        log_info "Old container stopped."
    fi
}

# Check if the new container is healthy
verify_container_health() {
    local target="$1"
    local timeout="${2:-60}"
    local interval="${3:-3}"
    local health_url="${4:-}"
    local health_cmd="${5:-}"

    log_info "Checking if container is healthy (waiting up to ${timeout}s)..."

    local elapsed=0
    local start_time
    start_time=$(date +%s)
    local stable_seconds=0
    local min_stable=8

    while [ "$elapsed" -lt "$timeout" ]; do
        local is_running exit_code
        is_running=$(docker inspect --format '{{.State.Running}}' "$target" 2>/dev/null || echo "false")
        exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$target" 2>/dev/null || echo "-1")

        if [ "$is_running" != "true" ]; then
            log_error "Container stopped unexpectedly! (Exit code: ${exit_code})"
            return 1
        fi

        local health_status
        health_status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$target" 2>/dev/null || echo "none")

        if [ "$health_status" = "healthy" ]; then
            log_success "Container is healthy and working! (${elapsed}s)"
            return 0
        elif [ "$health_status" = "unhealthy" ]; then
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
                    log_success "Health check URL returned OK! (${elapsed}s)"
                    return 0
                fi
            elif [ -n "$health_cmd" ]; then
                debug "Running custom health command: ${health_cmd}"
                if eval "$health_cmd" >/dev/null 2>&1; then
                    log_success "Custom health command passed!"
                    return 0
                fi
            else
                stable_seconds=$((stable_seconds + interval))
                if [ "$stable_seconds" -ge "$min_stable" ]; then
                    log_success "Container is running stably with no crashes."
                    return 0
                fi
            fi
        fi

        sleep "$interval"
        local now
        now=$(date +%s)
        elapsed=$((now - start_time))
    done

    log_error "Health check timed out after ${timeout}s without becoming healthy."
    return 1
}

# Roll back to the previous working container
rollback_container() {
    local target="$1"
    local backup_target="${target}${BACKUP_SUFFIX}"

    echo ""
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

    log_info "Cleaning up old unused images and build cache..."
    local dangling
    dangling=$(docker images -f "dangling=true" -q)
    if [ -n "$dangling" ]; then
        docker rmi $dangling >/dev/null 2>&1 || true
    fi
    docker image prune -f >/dev/null 2>&1 || true
    docker builder prune -f >/dev/null 2>&1 || true
    log_success "Cache cleanup finished."
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

    echo -e "\n${C_BOLD}Active Containers:${C_RESET}"
    local containers=()
    local i=1

    while IFS=$'\t' read -r name status image; do
        if [ -n "$name" ]; then
            containers+=("$name")
            printf "  %2d. %-26s %-22s %s\n" "$i" "$name" "$image" "${C_DIM}(${status})${C_RESET}"
            ((i++))
        fi
    done < <(docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true)

    if [ ${#containers[@]} -eq 0 ]; then
        echo "  (No containers found)"
    fi
    echo "   0. Enter name manually"
    echo ""

    local choice
    read -r -p "› Select container [number or name]: " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#containers[@]}" ]; then
        CONTAINER_NAME="${containers[$((choice - 1))]}"
    elif [ "$choice" = "0" ] || [ -z "$choice" ]; then
        read -r -p "› Container name: " CONTAINER_NAME
    else
        CONTAINER_NAME="$choice"
    fi

    if [ -z "${CONTAINER_NAME}" ]; then
        log_error "No container selected. Exiting."
        exit 1
    fi
}

# Interactive Update Details
prompt_update_details() {
    prompt_container_selection

    if [ "${INTERACTIVE_MODE:-false}" != "true" ] || [ ! -t 0 ]; then
        return 0
    fi

    if [ -z "${IMAGE_NAME}" ]; then
        local detected_img
        detected_img=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
        read -r -p "› Image to deploy [default: ${detected_img:-latest}]: " input_img
        IMAGE_NAME="${input_img:-$detected_img}"
    fi

    read -r -p "› Stop wait time in seconds [default: ${STOP_TIMEOUT}]: " input_stop
    [ -n "$input_stop" ] && STOP_TIMEOUT="$input_stop"

    read -r -p "› Health check wait time in seconds [default: ${HEALTH_TIMEOUT}]: " input_health
    [ -n "$input_health" ] && HEALTH_TIMEOUT="$input_health"

    echo ""
    echo -e "${C_DIM}──────────────────────────────────────────${C_RESET}"
    echo -e "  Container : ${C_BOLD}${CONTAINER_NAME}${C_RESET}"
    echo -e "  Image     : ${IMAGE_NAME}"
    echo -e "  Stop Wait : ${STOP_TIMEOUT}s"
    echo -e "  Check Wait: ${HEALTH_TIMEOUT}s"
    echo -e "${C_DIM}──────────────────────────────────────────${C_RESET}"
    echo ""
    read -r -p "› Start update now? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        log_warn "Update cancelled."
        exit 0
    fi
}

# Minimalist Main Menu
interactive_menu() {
    export INTERACTIVE_MODE="true"
    echo ""
    echo -e "${C_BOLD}Docker Auto-Updater${C_RESET}"
    echo -e "${C_DIM}──────────────────────────────────────────${C_RESET}"
    echo "  1. Update a container"
    echo "  2. Check container status"
    echo "  3. Undo last update (Rollback)"
    echo "  4. Clean unused Docker cache"
    echo "  5. Auto-update on new push (Watch mode)"
    echo "  6. Start webhook listener"
    echo "  0. Exit"
    echo -e "${C_DIM}──────────────────────────────────────────${C_RESET}"

    local menu_choice
    read -r -p "› Select an option [0-6]: " menu_choice

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
            read -r -p "› Check interval in seconds [default: ${WATCH_INTERVAL}]: " input_int
            [ -n "$input_int" ] && WATCH_INTERVAL="$input_int"
            do_watch
            ;;
        6)
            read -r -p "› Webhook port [default: ${WEBHOOK_PORT}]: " input_port
            [ -n "$input_port" ] && WEBHOOK_PORT="$input_port"
            read -r -p "› Secret token (optional) [default: ${WEBHOOK_SECRET}]: " input_sec
            [ -n "$input_sec" ] && WEBHOOK_SECRET="$input_sec"
            do_webhook
            ;;
        0)
            echo "Bye!"
            exit 0
            ;;
        *)
            log_error "Invalid option."
            exit 1
            ;;
    esac
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
    log_info "Pulling latest image: ${IMAGE_NAME}..."
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[dry-run] Would pull image: ${IMAGE_NAME}"
    elif [ "${SKIP_PULL:-false}" = "true" ]; then
        log_info "Skipping pull (local mode)."
    else
        if ! docker pull "${IMAGE_NAME}"; then
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

    log_step "Watching for updates on: ${CONTAINER_NAME} (every ${WATCH_INTERVAL}s)"
    echo "  Press Ctrl+C to stop."

    while true; do
        log_info "Checking registry for new image..."
        ( do_update ) || {
            log_warn "Check returned error or rolled back."
        }
        sleep "${WATCH_INTERVAL}"
    done
}

# Lightweight Webhook Listener
do_webhook() {
    check_dependencies
    log_step "Starting webhook listener on port ${WEBHOOK_PORT}..."
    if [ -n "${WEBHOOK_SECRET}" ]; then
        log_info "Protected by secret token."
    else
        log_warn "No secret token set. Anyone can trigger this endpoint."
    fi

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

    echo ""
    echo -e "${C_BOLD}Container: ${CONTAINER_NAME}${C_RESET}"
    echo -e "${C_DIM}──────────────────────────────────────────${C_RESET}"
    docker inspect --format '
  Status : {{.State.Status}}
  Running: {{.State.Running}}
  Health : {{if .State.Health}}{{.State.Health.Status}}{{else}}None configured{{end}}
  Image  : {{.Config.Image}}
  Restart: {{.HostConfig.RestartPolicy.Name}}
  Ports  : {{range $p, $conf := .NetworkSettings.Ports}}{{$p}} -> {{(index $conf 0).HostPort}} {{end}}
' "${CONTAINER_NAME}"
    echo -e "${C_DIM}──────────────────────────────────────────${C_RESET}"

    local backup_target="${CONTAINER_NAME}${BACKUP_SUFFIX}"
    if docker inspect "${backup_target}" >/dev/null 2>&1; then
        echo -e "  ${C_YELLOW}Backup exists:${C_RESET} ${backup_target} (available for rollback)"
    fi
    echo ""
}

# Clean Command
do_prune() {
    check_dependencies
    clean_dangling_caches
}

# Help Menu
show_help() {
    echo -e "${C_BOLD}Docker Auto-Updater${C_RESET}
A simple, safe tool to update Docker containers with auto-rollback.

${C_BOLD}Usage:${C_RESET}
  $(basename "$0") [command] [options]

${C_BOLD}Commands:${C_RESET}
  update       Update a container (pull, safe stop, health check, rollback on fail) [default]
  rollback     Restore container to previous backup
  watch        Watch registry and update automatically on new image
  webhook      Run a lightweight webhook server
  status       Show container status and health
  prune        Clean up unused Docker images and cache
  help         Show this help screen

${C_BOLD}Options:${C_RESET}
  -c, --container <name>     Container name (required for automated runs)
  -i, --image <name:tag>     Image to use (default: container's current image)
  -t, --stop-timeout <secs>  Safe stop wait time in seconds (default: 15)
  --health-timeout <secs>    Health check wait time in seconds (default: 60)
  --health-interval <secs>   Time between health checks in seconds (default: 3)
  --health-url <url>         Custom HTTP check URL (e.g. http://localhost:8080/health)
  --health-cmd <cmd>         Custom shell command to check health
  --force                    Force re-deployment even if image did not change
  --interactive              Show interactive prompts
  --no-prune                 Do not clean up unused cache after update
  --dry-run                  Preview steps without changing anything
  -v, --verbose              Show debug logs
  -h, --help                 Show this help screen

${C_BOLD}Examples:${C_RESET}
  $(basename "$0")                              # Opens interactive menu
  $(basename "$0") update -c my-web-app         # Direct update
  $(basename "$0") status -c my-web-app         # Check status
  $(basename "$0") rollback -c my-web-app       # Roll back
  $(basename "$0") prune                        # Clean cache
"
}

# Entrypoint
main() {
    load_config

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
