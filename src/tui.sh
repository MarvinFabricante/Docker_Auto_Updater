#!/usr/bin/env bash
# tui.sh - UI rendering, animations, menu loops, and layout

# Animation & UX Assets
SPIN_CHARS=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
BAR_FULL="████████████████████"
BAR_EMPTY="░░░░░░░░░░░░░░░░░░░░"
IS_FULLSCREEN="false"

is_interactive_tty() {
    [ -t 1 ] && [ "${NO_ANIMATION:-false}" != "true" ] && [ "${TERM:-}" != "dumb" ]
}

clear_screen() {
    clear 2>/dev/null || printf "\033[2J\033[H" 2>/dev/null || true
}

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
        # Restore scroll mode and disable mouse tracking
        echo -ne "\033[?1007h" 2>/dev/null || true
        echo -ne "\033[?1000l\033[?1002l\033[?1003l\033[?1006l" 2>/dev/null || true
        # Leave alternate screen buffer
        tput rmcup 2>/dev/null || echo -ne "\033[?1049l"
    fi
    # Always ensure cursor is visible, styling is reset, and terminal line discipline restored
    echo -ne "\033[?25h\033[0m" 2>/dev/null || true
    stty echo icanon 2>/dev/null || stty echo icanon < /dev/tty 2>/dev/null || true
}

cleanup_terminal() {
    exit_fullscreen
}

handle_exit_signal() {
    trap - EXIT INT TERM
    exit_fullscreen
    echo ""
    echo -e "  ${C_DIM}Docker Auto-Updater closed.${C_RESET}"
    echo ""
    exit 0
}

trap cleanup_terminal EXIT
trap handle_exit_signal INT TERM

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
    stty -echo 2>/dev/null || stty -echo < /dev/tty 2>/dev/null || true

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
            stty echo icanon 2>/dev/null || stty echo icanon < /dev/tty 2>/dev/null || true
            printf "\n"
            return 130
        fi

        # Ctrl+D
        if [ "$char" = $'\004' ]; then
            stty echo icanon 2>/dev/null || stty echo icanon < /dev/tty 2>/dev/null || true
            printf "\n"
            return 1
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

    stty echo icanon 2>/dev/null || stty echo icanon < /dev/tty 2>/dev/null || true

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

    stty -echo 2>/dev/null || stty -echo < /dev/tty 2>/dev/null || true

    while true; do
        local key=""
        IFS= read -rsn1 key || {
            # EOF (e.g. Ctrl+D)
            stty echo icanon 2>/dev/null || stty echo icanon < /dev/tty 2>/dev/null || true
            out_key="q"
            return 0
        }

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
            stty echo icanon 2>/dev/null || stty echo icanon < /dev/tty 2>/dev/null || true
            exit_fullscreen
            echo ""
            echo -e "  ${C_CYAN}Docker Auto-Updater closed. Bye!${C_RESET}"
            echo ""
            exit 0
        fi

        # Check for Ctrl+D
        if [ "$key" = $'\004' ]; then
            stty echo icanon 2>/dev/null || stty echo icanon < /dev/tty 2>/dev/null || true
            exit_fullscreen
            echo ""
            echo -e "  ${C_CYAN}Docker Auto-Updater closed. Bye!${C_RESET}"
            echo ""
            exit 0
        fi

        if [[ "$key" =~ ^[0-6qQ]$ ]]; then
            printf "%s\n" "$key"
            out_key="$key"
            stty echo icanon 2>/dev/null || stty echo icanon < /dev/tty 2>/dev/null || true
            return 0
        fi
    done

    stty echo icanon 2>/dev/null || stty echo icanon < /dev/tty 2>/dev/null || true
    return 1
}

pause_and_return() {
    if [ "${INTERACTIVE_MODE:-false}" = "true" ] && is_interactive_tty; then
        echo ""
        echo -e "  ${C_DIM}───────────────────────────────────────────────────────────────────────────${C_RESET}"
        printf "  Press [Enter] to return to dashboard (or 'q' to exit)... "
        stty -echo 2>/dev/null || stty -echo < /dev/tty 2>/dev/null || true

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

            # Check for Enter
            if [ -z "$key" ] || [ "$key" = $'\n' ] || [ "$key" = $'\r' ]; then
                break
            fi

            # Check for q, Q, or 0 to exit directly
            if [ "$key" = "q" ] || [ "$key" = "Q" ] || [ "$key" = "0" ]; then
                exit_fullscreen
                echo ""
                echo -e "  ${C_CYAN}Docker Auto-Updater closed. Bye!${C_RESET}"
                echo ""
                exit 0
            fi

            # Check for Ctrl+C or Ctrl+D
            if [ "$key" = $'\003' ] || [ "$key" = $'\004' ]; then
                exit_fullscreen
                echo ""
                echo -e "  ${C_CYAN}Docker Auto-Updater closed. Bye!${C_RESET}"
                echo ""
                exit 0
            fi
        done
        stty echo icanon 2>/dev/null || stty echo icanon < /dev/tty 2>/dev/null || true
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

# Interactive Container Selection
prompt_container_selection() {
    if [ -n "${CONTAINER_NAME:-}" ]; then
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
    echo -e "  ${C_CYAN}│${C_RESET} ${C_BOLD}q${C_RESET}    Back to main menu (or 'c' to cancel)"
    echo -e "  ${C_CYAN}╰────────────────────────────────────────────────────────────────────────────────╯${C_RESET}"
    echo ""

    local choice=""
    safe_read_line "  › Select container [number, name, or 'q' to back]: " "" choice
    local rc=$?
    if [ $rc -ne 0 ]; then
        return 1
    fi

    if [[ "$choice" =~ ^(c|C|cancel|q|Q|quit|back|exit)$ ]]; then
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

    if [ -z "${IMAGE_NAME:-}" ]; then
        local detected_img
        detected_img=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
        safe_read_line "  › Image to deploy [default: ${detected_img:-latest}]: " "${detected_img:-latest}" IMAGE_NAME
        [ $? -ne 0 ] && return 1
    fi

    local input_stop=""
    safe_read_line "  › Stop wait time in seconds [default: ${STOP_TIMEOUT}]: " "${STOP_TIMEOUT}" input_stop
    [ $? -ne 0 ] && return 1
    [ -n "$input_stop" ] && STOP_TIMEOUT="$input_stop"

    local input_health=""
    safe_read_line "  › Health check wait time in seconds [default: ${HEALTH_TIMEOUT}]: " "${HEALTH_TIMEOUT}" input_health
    [ $? -ne 0 ] && return 1
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
    [ $? -ne 0 ] && return 1
    [ -n "$input_int" ] && WATCH_INTERVAL="$input_int"
    do_watch
}

do_webhook_interactive() {
    local input_port=""
    safe_read_line "  › Webhook port [default: ${WEBHOOK_PORT}]: " "${WEBHOOK_PORT}" input_port
    [ $? -ne 0 ] && return 1
    [ -n "$input_port" ] && WEBHOOK_PORT="$input_port"
    local input_sec=""
    safe_read_line "  › Secret token (optional) [default: ${WEBHOOK_SECRET}]: " "${WEBHOOK_SECRET}" input_sec
    [ $? -ne 0 ] && return 1
    [ -n "$input_sec" ] && WEBHOOK_SECRET="$input_sec"
    do_webhook
}

# Interactive Full-Screen Main Application Loop
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
            echo ""
            echo -e "  ${C_CYAN}Docker Auto-Updater closed. Bye!${C_RESET}"
            echo ""
            exit 0
        fi

        case "$menu_choice" in
            1)
                clear_screen
                CONTAINER_NAME=""
                IMAGE_NAME=""
                if prompt_update_details; then
                    do_update || true
                    pause_and_return
                fi
                ;;
            2)
                clear_screen
                CONTAINER_NAME=""
                if prompt_container_selection; then
                    do_status || true
                    pause_and_return
                fi
                ;;
            3)
                clear_screen
                CONTAINER_NAME=""
                if prompt_container_selection; then
                    do_manual_rollback || true
                    pause_and_return
                fi
                ;;
            4)
                clear_screen
                echo ""
                do_prune || true
                pause_and_return
                ;;
            5)
                clear_screen
                CONTAINER_NAME=""
                if prompt_container_selection; then
                    do_watch_interactive || true
                    pause_and_return
                fi
                ;;
            6)
                clear_screen
                do_webhook_interactive || true
                pause_and_return
                ;;
            0|[Qq]|[Qq][Uu][Ii][Tt]|"exit")
                exit_fullscreen
                echo ""
                echo -e "  ${C_CYAN}Docker Auto-Updater closed. Bye!${C_RESET}"
                echo ""
                exit 0
                ;;
            *)
                echo -e "  ${I_ERR} Invalid option. Please select 0-6 or 'q'."
                sleep 1
                ;;
        esac
    done
}
