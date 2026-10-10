#!/usr/bin/env bash
# core_engine.sh - Pure Docker commands: pull, update, rollback, prune, health check, status

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
    local backup_target="${target}${BACKUP_SUFFIX:-_rollback}"

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
    if [ "${AUTO_PRUNE:-true}" != "true" ]; then
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
    if [ -z "${IMAGE_NAME:-}" ]; then
        IMAGE_NAME="${current_image_ref}"
        log_info "Using container image: ${IMAGE_NAME}"
    fi

    local backup_target="${CONTAINER_NAME}${BACKUP_SUFFIX:-_rollback}"

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
    if [ "${DRY_RUN:-false}" = "true" ]; then
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
    if [ "${old_image_id}" = "${new_image_id}" ] && [ "${FORCE_UPDATE:-false}" != "true" ]; then
        log_success "Image '${IMAGE_NAME}' is already up to date. Nothing to do."
        exit 0
    fi

    if [ "${DRY_RUN:-false}" = "true" ]; then
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
    stop_container_gracefully "${CONTAINER_NAME}" "${STOP_TIMEOUT:-15}"

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
    if ! verify_container_health "${CONTAINER_NAME}" "${HEALTH_TIMEOUT:-60}" "${HEALTH_INTERVAL:-3}" "${HEALTH_URL:-}" "${HEALTH_CMD:-}"; then
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
    printf "  ${C_CYAN}│${C_RESET}  Polling Interval : %ss\n" "${WATCH_INTERVAL:-60}"
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
            for (( w=${WATCH_INTERVAL:-60}; w>0; w-- )); do
                local frame="${SPIN_CHARS[$(( (${WATCH_INTERVAL:-60} - w) % ${#SPIN_CHARS[@]} ))]}"
                printf "\r  ${C_CYAN}%s${C_RESET} Next check in ${C_BOLD}%ds${C_RESET}... ${C_DIM}(Ctrl+C to stop)${C_RESET}\033[K" "$frame" "$w"
                sleep 1
            done
            printf "\r\033[K"
        else
            sleep "${WATCH_INTERVAL:-60}"
        fi
    done
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

    local backup_target="${CONTAINER_NAME}${BACKUP_SUFFIX:-_rollback}"
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
