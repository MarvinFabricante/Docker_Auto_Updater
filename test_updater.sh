#!/usr/bin/env bash
# Integration Test Suite for Docker Container Auto-Updater
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATER="${SCRIPT_DIR}/container.sh"
TEST_CONTAINER="ci_test_app"
TEST_IMAGE_V1="ci-test-service:v1"
TEST_IMAGE_V2="ci-test-service:v2"
TEST_IMAGE_BROKEN="ci-test-service:broken"

cleanup() {
    echo -e "\n Cleaning up test resources..."
    docker rm -f "${TEST_CONTAINER}" "${TEST_CONTAINER}_rollback" 2>/dev/null || true
    docker rmi -f "${TEST_IMAGE_V1}" "${TEST_IMAGE_V2}" "${TEST_IMAGE_BROKEN}" 2>/dev/null || true
}
trap cleanup EXIT

echo "------------------------------------------------------------------------"
echo "  RUNNING CI/CD CONTAINER AUTO-UPDATER TEST SUITE"
echo "------------------------------------------------------------------------"

# 1. Build test images
echo -e "\n 1. Building Mock Docker Images (v1, v2, broken)..."

# Image v1 (Healthy Python HTTP Server)
docker build -t "${TEST_IMAGE_V1}" - << 'EOF'
FROM alpine:3.20
RUN apk add --no-cache curl python3
HEALTHCHECK --interval=2s --timeout=2s --retries=3 CMD curl -sf http://localhost:8080/ || exit 1
CMD ["python3", "-m", "http.server", "8080"]
EOF

# Image v2 (Healthy newer version)
docker build -t "${TEST_IMAGE_V2}" - << 'EOF'
FROM alpine:3.20
RUN apk add --no-cache curl python3
HEALTHCHECK --interval=2s --timeout=2s --retries=3 CMD curl -sf http://localhost:8080/ || exit 1
CMD ["python3", "-m", "http.server", "8080"]
EOF

# Image Broken (Fails health check: exit 1)
docker build -t "${TEST_IMAGE_BROKEN}" - << 'EOF'
FROM alpine:3.20
HEALTHCHECK --interval=1s --timeout=1s --retries=1 CMD exit 1
CMD ["sleep", "300"]
EOF

# 2. Start initial container with v1
echo -e "\n 2. Launching initial container '${TEST_CONTAINER}' with image '${TEST_IMAGE_V1}'..."
docker run -d --name "${TEST_CONTAINER}" -p 18080:8080 "${TEST_IMAGE_V1}"

echo "Waiting for initial container to report healthy..."
for i in $(seq 1 15); do
    STATUS=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${TEST_CONTAINER}" 2>/dev/null || echo "none")
    echo "Health status: ${STATUS} (${i}s)"
    if [ "${STATUS}" = "healthy" ]; then
        break
    fi
    sleep 1
done

if [ "${STATUS}" != "healthy" ]; then
    echo " Error: Initial container failed to become healthy!"
    exit 1
fi
echo "Initial container is healthy."

# 3. Test Successful Update (v1 -> v2)
echo -e "\n3. Testing SUCCESSFUL update from v1 to v2..."
"${UPDATER}" update \
    --container "${TEST_CONTAINER}" \
    --image "${TEST_IMAGE_V2}" \
    --skip-pull \
    --health-timeout 20 \
    --health-interval 2 \
    --stop-timeout 5

echo "Verifying v2 is running..."
RUNNING_IMAGE=$(docker inspect --format '{{.Config.Image}}' "${TEST_CONTAINER}")
HEALTH_V2=$(docker inspect --format '{{.State.Health.Status}}' "${TEST_CONTAINER}")
echo "Current Container Image: ${RUNNING_IMAGE}"
echo "Current Health: ${HEALTH_V2}"

if [ "${RUNNING_IMAGE}" != "${TEST_IMAGE_V2}" ] || [ "${HEALTH_V2}" != "healthy" ]; then
    echo "Error: Update to v2 did not succeed as expected!"
    exit 1
fi
echo "Test 1 PASSED: Successfully updated to v2 and verified health."

# 4. Test Automatic Rollback on Broken Image (v2 -> broken)
echo -e "\n4. Testing AUTOMATIC ROLLBACK when updating to broken image..."
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
    echo "Error: Updater should have failed and returned non-zero exit code!"
    exit 1
fi
echo "Updater correctly returned non-zero exit code ($EXIT_CODE) indicating rollback was triggered."

# Verify the container was rolled back to v2 and is running
ROLLED_BACK_IMAGE=$(docker inspect --format '{{.Config.Image}}' "${TEST_CONTAINER}")
ROLLED_BACK_STATUS=$(docker inspect --format '{{.State.Running}}' "${TEST_CONTAINER}")

echo "Post-Rollback Container Image: ${ROLLED_BACK_IMAGE}"
echo "Post-Rollback Running State: ${ROLLED_BACK_STATUS}"

if [ "${ROLLED_BACK_IMAGE}" != "${TEST_IMAGE_V2}" ] || [ "${ROLLED_BACK_STATUS}" != "true" ]; then
    echo "Error: Automatic rollback failed! Container was not restored to ${TEST_IMAGE_V2}."
    exit 1
fi
echo "Test 2 PASSED: Automatic rollback successfully restored stable version ${TEST_IMAGE_V2}!"

# 5. Test Dangling Cache Pruning
echo -e "\n 5. Testing Dangling Cache Pruning..."
"${UPDATER}" prune
echo "Test 3 PASSED: Cache prune executed successfully."

echo -e "\n ALL INTEGRATION TESTS PASSED SUCCESSFULLY! \n"
