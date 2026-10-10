#!/usr/bin/env bash
# Integration test suite for Docker Auto-Updater
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATER="${SCRIPT_DIR}/container.sh"
TEST_CONTAINER="ci_test_app"
TEST_IMAGE_V1="ci-test-service:v1"
TEST_IMAGE_V2="ci-test-service:v2"
TEST_IMAGE_BROKEN="ci-test-service:broken"

cleanup() {
    echo ""
    echo "• Cleaning up test containers and images..."
    docker rm -f "${TEST_CONTAINER}" "${TEST_CONTAINER}_rollback" 2>/dev/null || true
    docker rmi -f "${TEST_IMAGE_V1}" "${TEST_IMAGE_V2}" "${TEST_IMAGE_BROKEN}" 2>/dev/null || true
}
trap cleanup EXIT

echo "Docker Auto-Updater Tests"
echo "──────────────────────────────────────────"

# 1. Build test images
echo "1. Building test images (v1, v2, broken)..."

docker build -t "${TEST_IMAGE_V1}" - << 'EOF' >/dev/null 2>&1
FROM alpine:3.20
RUN apk add --no-cache curl python3 >/dev/null 2>&1
HEALTHCHECK --interval=2s --timeout=2s --retries=3 CMD curl -sf http://localhost:8080/ || exit 1
CMD ["python3", "-m", "http.server", "8080"]
EOF

docker build -t "${TEST_IMAGE_V2}" - << 'EOF' >/dev/null 2>&1
FROM alpine:3.20
RUN apk add --no-cache curl python3 >/dev/null 2>&1
HEALTHCHECK --interval=2s --timeout=2s --retries=3 CMD curl -sf http://localhost:8080/ || exit 1
CMD ["python3", "-m", "http.server", "8080"]
EOF

docker build -t "${TEST_IMAGE_BROKEN}" - << 'EOF' >/dev/null 2>&1
FROM alpine:3.20
HEALTHCHECK --interval=1s --timeout=1s --retries=1 CMD exit 1
CMD ["sleep", "300"]
EOF

# 2. Start initial container
echo "2. Starting initial container..."
docker rm -f "${TEST_CONTAINER}" "${TEST_CONTAINER}_rollback" 2>/dev/null || true
docker run -d --name "${TEST_CONTAINER}" -p 18080:8080 "${TEST_IMAGE_V1}" >/dev/null

for i in $(seq 1 15); do
    STATUS=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${TEST_CONTAINER}" 2>/dev/null || echo "none")
    if [ "${STATUS}" = "healthy" ]; then
        break
    fi
    sleep 1
done

if [ "${STATUS}" != "healthy" ]; then
    echo "✖ Initial container failed to become healthy."
    exit 1
fi
echo "✔ Initial container is healthy."

# 3. Test Successful Update (v1 -> v2)
echo ""
echo "3. Testing successful update (v1 to v2)..."
"${UPDATER}" update \
    --container "${TEST_CONTAINER}" \
    --image "${TEST_IMAGE_V2}" \
    --skip-pull \
    --health-timeout 20 \
    --health-interval 2 \
    --stop-timeout 5

RUNNING_IMAGE=$(docker inspect --format '{{.Config.Image}}' "${TEST_CONTAINER}")
HEALTH_V2=$(docker inspect --format '{{.State.Health.Status}}' "${TEST_CONTAINER}")

if [ "${RUNNING_IMAGE}" != "${TEST_IMAGE_V2}" ] || [ "${HEALTH_V2}" != "healthy" ]; then
    echo "✖ Update test failed!"
    exit 1
fi
echo "✔ Test 1 passed: container updated to v2."

# 4. Test Automatic Rollback on Broken Image (v2 -> broken)
echo ""
echo "4. Testing auto-rollback on broken image..."
set +e
"${UPDATER}" update \
    --container "${TEST_CONTAINER}" \
    --image "${TEST_IMAGE_BROKEN}" \
    --skip-pull \
    --health-timeout 8 \
    --health-interval 1 \
    --stop-timeout 3
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -eq 0 ]; then
    echo "✖ Updater should have exited with an error on broken container!"
    exit 1
fi

ROLLED_BACK_IMAGE=$(docker inspect --format '{{.Config.Image}}' "${TEST_CONTAINER}")
ROLLED_BACK_STATUS=$(docker inspect --format '{{.State.Running}}' "${TEST_CONTAINER}")

if [ "${ROLLED_BACK_IMAGE}" != "${TEST_IMAGE_V2}" ] || [ "${ROLLED_BACK_STATUS}" != "true" ]; then
    echo "✖ Rollback failed: container not restored to v2!"
    exit 1
fi
echo "✔ Test 2 passed: auto-rollback restored stable v2."

# 5. Test Dangling Cache Pruning
echo ""
echo "5. Testing cache cleanup..."
"${UPDATER}" prune
echo "✔ Test 3 passed: cache cleanup works."

echo ""
echo "──────────────────────────────────────────"
echo "✔ All tests passed successfully!"
echo "──────────────────────────────────────────"
