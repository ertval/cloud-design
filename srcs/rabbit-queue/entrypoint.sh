#!/bin/bash
set -euo pipefail

: "${RABBITMQ_USER:?RABBITMQ_USER environment variable must be set}"
: "${RABBITMQ_PASSWORD:?RABBITMQ_PASSWORD environment variable must be set}"

mkdir -p /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq
chown -R rabbitmq:rabbitmq /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq

echo "[rabbit-queue] Starting RabbitMQ server in background..."
su-exec rabbitmq rabbitmq-server &
SERVER_PID=$!

# Trap signals for graceful shutdown
shutdown() {
    echo "[rabbit-queue] Received shutdown signal, stopping RabbitMQ..."
    su-exec rabbitmq rabbitmqctl stop || kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID"
    exit 0
}
trap shutdown SIGTERM SIGINT

echo "[rabbit-queue] Awaiting RabbitMQ startup..."
if command -v rabbitmqctl &>/dev/null; then
    for i in $(seq 1 60); do
        if rabbitmqctl await_startup 2>/dev/null; then
            echo "[rabbit-queue] RabbitMQ broker is online and ready."
            break
        fi
        [ "$i" -eq 60 ] && { echo "[rabbit-queue] RabbitMQ failed to start in time"; exit 1; }
        sleep 2
    done
fi

echo "[rabbit-queue] Configuring credentials and permissions for user '$RABBITMQ_USER'..."
rabbitmqctl add_user "$RABBITMQ_USER" "$RABBITMQ_PASSWORD" 2>/dev/null || \
    rabbitmqctl change_password "$RABBITMQ_USER" "$RABBITMQ_PASSWORD"

rabbitmqctl set_user_tags "$RABBITMQ_USER" administrator
rabbitmqctl set_permissions -p / "$RABBITMQ_USER" ".*" ".*" ".*"

# Delete default guest user if it exists for security hygiene
rabbitmqctl delete_user guest 2>/dev/null || true

echo "[rabbit-queue] RabbitMQ configuration complete. Monitoring process PID $SERVER_PID..."
wait "$SERVER_PID"

