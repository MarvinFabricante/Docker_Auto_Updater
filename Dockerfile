# Lightweight CI/CD Auto-Updater Container
FROM alpine:3.20

LABEL maintainer="Docker Container Auto-Updater"
LABEL description="Lightweight CI/CD auto-updater with health check verification and automatic rollback"

# Install Docker CLI, Bash, curl, jq, and Python 3
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    python3 \
    coreutils \
    docker-cli \
    tzdata

WORKDIR /app

# Copy automation script
COPY container.sh /usr/local/bin/container-updater
RUN chmod +x /usr/local/bin/container-updater && \
    ln -s /usr/local/bin/container-updater /app/container.sh

# Environment defaults
ENV CONTAINER_NAME="" \
    IMAGE_NAME="" \
    STOP_TIMEOUT="15" \
    HEALTH_TIMEOUT="60" \
    HEALTH_INTERVAL="3" \
    AUTO_PRUNE="true" \
    WATCH_INTERVAL="60" \
    WEBHOOK_PORT="9000"

EXPOSE 9000

ENTRYPOINT ["container-updater"]
CMD ["help"]
