# Docker Auto-Updater

A clean, simple tool to update Docker containers safely with automatic rollback.

When a new image is pushed:
1. Stops the old container safely (giving it time to shut down).
2. Pulls the new image from your registry.
3. Keeps a backup of the old container.
4. Checks if the new container is healthy and working.
5. If it fails or crashes, it rolls back to the old version right away.
6. Cleans up old, unused Docker images and cache.

---

## Quick Start

### 1. Interactive Full-Screen Application
Just run the script without any options (or `./container.sh menu`):
```bash
./container.sh
```
Launches an immersive, full-screen terminal application (TUI) with a live container overview, categorized operations, in-app navigation, animated progress indicators, and persistent screen loop. Press `q` or `0` to cleanly return to your shell.

### 2. Update a Container Directly
```bash
# Update using the container's current image
./container.sh update -c my-app

# Or specify a new image
./container.sh update -c my-app -i myrepo/my-app:latest
```

### 3. Check Container Status
```bash
./container.sh status -c my-app
```

### 4. Roll Back Manually
If you ever want to undo the last update:
```bash
./container.sh rollback -c my-app
```

### 5. Clean Up Old Cache
Removes unused images and build cache to save disk space:
```bash
./container.sh prune
```

---

## Automatic Modes

### Watch Mode (Check every X seconds)
Checks your registry regularly and updates when a new image is found:
```bash
./container.sh watch -c my-app --interval 60
```

### Webhook Mode (Update on push)
Runs a simple webhook server on your host:
```bash
./container.sh webhook --port 9000 --secret "my-token"
```

Trigger it from GitHub Actions, Docker Hub, or curl:
```bash
curl -X POST http://your-server:9000/webhook \
  -H "X-Webhook-Secret: my-token" \
  -H "Content-Type: application/json" \
  -d '{"container": "my-app"}'
```

---

## Settings (`.env`)

You can set these in a `.env` file or pass them as options:

| Setting | Default | What it does |
|---|---|---|
| `CONTAINER_NAME` | _None_ | Name of the container to update |
| `IMAGE_NAME` | _Auto_ | Docker image to use |
| `STOP_TIMEOUT` | `15` | Seconds to wait when stopping safely |
| `HEALTH_TIMEOUT` | `60` | Seconds to wait for health check |
| `HEALTH_INTERVAL` | `3` | Seconds between health checks |
| `HEALTH_URL` | _None_ | Custom web URL to check (e.g. `http://localhost:8080/health`) |
| `AUTO_PRUNE` | `true` | Clean unused images and cache after update |
| `WATCH_INTERVAL` | `60` | How often to check registry in watch mode |
| `WEBHOOK_PORT` | `9000` | Port for the webhook server |
| `WEBHOOK_SECRET` | _None_ | Secret token to secure the webhook |
| `NO_ANIMATION` | `false` | Disable animated spinners and live progress bars |
| `NO_COLOR` | _None_ | Disable ANSI colors (`--no-color` or `NO_COLOR=1`) |

---

## UI/UX & Animation Features

- **Live Animated Spinners & Tickers**: Smooth Braille spinners (`⠋ ⠙ ⠹...`) for Docker pulls, graceful container shutdowns, and cache pruning with real-time elapsed seconds.
- **Dynamic Health Progress Bar**: Real-time visual progress bar (`[████░░░░░░░░░░]`) and state indicator (`starting`, `healthy`, `unhealthy`) during container verification.
- **Interactive Container Dashboard**: Formatted table of local containers with status badges (🟢 Up, 🔴 Exited, 🟡 Restarting) and mapped ports.
- **Pre-flight Deployment Confirmation**: Styled summary card detailing container name, image digest, timeout thresholds, and safety rollback targets before execution.
- **Visual Alert Banners**: Highlighted warning cards on failed deployments with automatic rollback status.
- **CI/CD & Headless Friendly**: Automatically detects non-interactive terminals / pipelines to disable ANSI escapes and maintain deterministic log output. You can also explicitly pass `--no-animation` and `--no-color`.

---

## Requirements

- Docker
- `jq`
- `bash` (4.0+)
- `python3`

Make sure the script is executable:
```bash
chmod +x container.sh
```

---

## Run Tests

To test the update, health check, auto-rollback, and cache clean workflows:
```bash
./test_updater.sh
```
