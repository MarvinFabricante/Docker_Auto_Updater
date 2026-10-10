# Docker Container Auto-Updater & CI/CD Deployment Script

A lightweight, production-grade automation script for container continuous deployment. When a new image is pushed to your container registry, this script:
1. **Gracefully stops** the running container with a configurable timeout.
2. **Pulls the latest image** from your registry (comparing digests to prevent redundant restarts).
3. **Preserves the existing container** as an instant, zero-data-loss rollback safety net.
4. **Validates health status** via Docker native `HEALTHCHECK`, custom HTTP endpoints, or runtime stability tracking.
5. **Automatically rolls back** within seconds if the health check fails or the container crashes.
6. **Cleans up dangling Docker images and build caches** upon a successful deployment.

---

## Key Features

- **Zero-Downtime / Lossless Rollback**: Renames the existing container before recreation, preserving its ports, volumes, environment, and network state. If the new image fails health checks, the previous container is instantly restored without data loss.
- **Graceful Shutdown**: Sends `SIGTERM` and waits up to `STOP_TIMEOUT` seconds before forcefully terminating.
- **Multi-Level Health Checking**:
  - Native Docker `HEALTHCHECK` (monitors `.State.Health.Status` until `healthy` or `unhealthy`).
  - Custom HTTP Endpoint (`--health-url http://localhost:8080/health`).
  - Runtime crash detection (`.State.Running == false` or non-zero exit codes).
- **Automated Cache & Layer Pruning**: Prunes untagged `<none>` images and dangling builder caches (`docker image prune` & `docker builder prune`).
- **Flexible Trigger Modes**:
  - **Direct CI/CD step**: Triggered from GitHub Actions, GitLab CI, or Jenkins.
  - **Watcher Daemon**: Periodically polls the registry digest and triggers deployment on change.
  - **Lightweight Webhook Server**: Built-in HTTP server listening for webhooks from Docker Hub, Harbor, or custom curl requests.
- **Containerized or Bare-Metal**: Run directly as a shell script on Linux or as an Alpine-based Docker container.

---

## Installation & Prerequisites

Dependencies required on host:
- Docker (`docker-cli` and daemon)
- `jq`
- `bash` (4.0+)
- `python3` (for webhook server and argument serialization)

Make the script executable:
```bash
chmod +x container.sh
```

---

## Usage & Commands

### 1. Manual / CI Pipeline Execution
```bash
# Update container using its current image
./container.sh update --container my-web-app

# Update specifying image, stop timeout, and health timeout
./container.sh update \
  --container my-web-app \
  --image myregistry.azurecr.io/team/my-web-app:latest \
  --stop-timeout 15 \
  --health-timeout 60 \
  --health-interval 3
```

### 2. Custom HTTP Health Check
For images without a `HEALTHCHECK` instruction in their Dockerfile:
```bash
./container.sh update \
  --container my-web-app \
  --health-url http://localhost:8080/health
```

### 3. Continuous Registry Polling (Watch Mode)
Polls the registry digest every 60 seconds and updates automatically when a new digest is detected:
```bash
./container.sh watch --container my-web-app --interval 60
```

### 4. HTTP Webhook Listener
Starts a lightweight built-in HTTP server on port 9000:
```bash
./container.sh webhook --port 9000 --secret "my-secure-token"
```

Trigger the webhook from your CI pipeline or Docker Hub:
```bash
curl -X POST http://your-server-ip:9000/webhook \
  -H "X-Webhook-Secret: my-secure-token" \
  -H "Content-Type: application/json" \
  -d '{"container": "my-web-app", "image": "myregistry.azurecr.io/team/my-web-app:latest"}'
```

### 5. Check Container Status
```bash
./container.sh status --container my-web-app
```

### 6. Clean Dangling Docker Caches
```bash
./container.sh prune
```

---

## Configuration (`.env`)

You can set options in `.env` or pass them as CLI flags:

| Variable | Default | Description |
|---|---|---|
| `CONTAINER_NAME` | _None_ | Name of the target Docker container |
| `IMAGE_NAME` | _Auto-detected_ | Target image name and tag |
| `STOP_TIMEOUT` | `15` | Seconds to wait for graceful stop before SIGKILL |
| `HEALTH_TIMEOUT` | `60` | Max seconds to wait for healthy status |
| `HEALTH_INTERVAL` | `3` | Seconds between health check queries |
| `HEALTH_URL` | _None_ | Optional HTTP endpoint to poll for health |
| `AUTO_PRUNE` | `true` | Automatically prune dangling images/cache on success |
| `FORCE_UPDATE` | `false` | Recreate container even if image digest is unchanged |
| `WATCH_INTERVAL` | `60` | Polling interval in seconds for `watch` mode |
| `WEBHOOK_PORT` | `9000` | Port for the built-in webhook listener |
| `WEBHOOK_SECRET` | _None_ | Secret token required in `X-Webhook-Secret` |
| `DISCORD_WEBHOOK_URL` | _None_ | Optional Discord webhook for deployment alerts |
| `SLACK_WEBHOOK_URL` | _None_ | Optional Slack webhook for deployment alerts |

---

## Containerized Deployment (Docker-in-Docker)

You can run the auto-updater itself inside a Docker container by mounting the host Docker socket:

```bash
# Build the updater image
docker build -t container-auto-updater .

# Run the webhook listener inside Docker
docker run -d \
  --name auto-updater \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 9000:9000 \
  -e WEBHOOK_PORT=9000 \
  -e WEBHOOK_SECRET="my-secure-token" \
  container-auto-updater webhook
```

---

## CI/CD Integration Examples

### GitHub Actions
```yaml
name: Build, Push and Deploy
on:
  push:
    branches: [ "main" ]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Build & Push Docker Image
        run: |
          docker build -t myregistry.com/app:latest .
          docker push myregistry.com/app:latest

      - name: Trigger Webhook on Deployment Server
        run: |
          curl -f -X POST https://deploy.example.com:9000/webhook \
            -H "X-Webhook-Secret: ${{ secrets.DEPLOY_SECRET }}" \
            -H "Content-Type: application/json" \
            -d '{"container":"production-app"}'
```

---

## Testing

Run the included integration test suite to verify graceful stops, successful rollouts, health check validation, automatic rollbacks, and cache cleanup:

```bash
./test_updater.sh
```
