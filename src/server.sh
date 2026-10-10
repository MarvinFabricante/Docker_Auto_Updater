#!/usr/bin/env bash
# server.sh - Webhook server logic, port listening, and token validation

# Lightweight Webhook Listener
do_webhook() {
    check_dependencies
    echo ""
    echo -e "  ${C_CYAN}╭──   Docker Webhook Server Online ──────────────────────────╮${C_RESET}"
    printf "  ${C_CYAN}│${C_RESET}  Endpoint : ${C_BOLD}${C_CYAN}http://0.0.0.0:%s/webhook${C_RESET}\n" "${WEBHOOK_PORT:-9000}"
    if [ -n "${WEBHOOK_SECRET:-}" ]; then
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
' "${MAIN_SCRIPT:-$0}"
}
