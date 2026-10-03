#!/bin/bash
set -euo pipefail

: "${RABBITMQ_USER:?RABBITMQ_USER environment variable must be set}"
: "${RABBITMQ_PASSWORD:?RABBITMQ_PASSWORD environment variable must be set}"

# `guest` is the broker's built-in default account. Configuring it and then
# deleting it (below) would leave the broker with zero usable users, so reject
# the name up front with an actionable message instead of failing later.
if [ "$RABBITMQ_USER" = "guest" ]; then
    echo "[rabbit-queue] ERROR: RABBITMQ_USER must not be 'guest' - that is the built-in default account which this entrypoint removes." >&2
    exit 1
fi

# Readiness sentinel, consumed by docker-compose's healthcheck (and by the k8s
# readinessProbe in manifests/rabbitmq.yaml).
# Lives in /tmp (NOT /var/lib/rabbitmq) on purpose: /var/lib/rabbitmq is the
# persistent volume, so a sentinel there would still be present on the next
# container start and the probe would report Ready before this broker had been
# configured. /tmp is part of the container filesystem, so it is always empty
# at boot and only appears once configuration below has fully succeeded.
READY_SENTINEL=/tmp/rabbit-queue-ready
rm -f "${READY_SENTINEL}"

mkdir -p /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq
chown -R rabbitmq:rabbitmq /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq

# `rabbitmqctl` run as root needs root's erlang cookie to match the one the
# broker (running as the rabbitmq user) generated, otherwise every CLI call
# fails with "CookieMismatch" while the broker itself looks perfectly healthy.
sync_erlang_cookie() {
    if [ -f /var/lib/rabbitmq/.erlang.cookie ] && [ ! -f /root/.erlang.cookie ]; then
        cp -f /var/lib/rabbitmq/.erlang.cookie /root/.erlang.cookie 2>/dev/null || true
        chmod 400 /root/.erlang.cookie 2>/dev/null || true
    fi
}

echo "[rabbit-queue] Starting RabbitMQ server in background..."
su-exec rabbitmq rabbitmq-server &
SERVER_PID=$!

# Trap signals for graceful shutdown
shutdown() {
    echo "[rabbit-queue] Received shutdown signal, stopping RabbitMQ..."
    sync_erlang_cookie
    su-exec rabbitmq rabbitmqctl stop 2>/dev/null || kill -TERM "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID"
    exit 0
}
trap shutdown SIGTERM SIGINT

echo "[rabbit-queue] Awaiting RabbitMQ startup..."
if command -v rabbitmqctl &>/dev/null; then
    for i in $(seq 1 60); do
        sync_erlang_cookie
        if su-exec rabbitmq rabbitmqctl await_startup 2>/dev/null; then
            echo "[rabbit-queue] RabbitMQ broker is online and ready."
            break
        fi
        [ "$i" -eq 60 ] && { echo "[rabbit-queue] RabbitMQ failed to start in time"; exit 1; }
        sleep 2
    done
fi

sync_erlang_cookie

echo "[rabbit-queue] Configuring credentials and permissions for user '$RABBITMQ_USER'..."

# The password is fed on stdin, never as a command-line argument. Anything in
# argv is world-readable through /proc/<pid>/cmdline for the whole lifetime of
# the process, so `rabbitmqctl add_user "$user" "$pass"` would expose it. With
# this form rabbitmqctl prompts for the password and reads it from stdin.
# Every CLI call runs through su-exec: the official image ships rabbitmqctl in
# /usr/local/bin, but a bare call as root can pick up a different Erlang home
# and fail with a cookie mismatch.
user_exists() {
    su-exec rabbitmq rabbitmqctl list_users --silent 2>/dev/null | awk '{print $1}' | grep -qx "$RABBITMQ_USER"
}

if user_exists; then
    # Reconcile on every boot so a rotated credential in .env takes effect.
    printf '%s\n' "$RABBITMQ_PASSWORD" | su-exec rabbitmq rabbitmqctl change_password "$RABBITMQ_USER" >/dev/null
    echo "[rabbit-queue] Existing user '$RABBITMQ_USER' password synchronised."
else
    printf '%s\n' "$RABBITMQ_PASSWORD" | su-exec rabbitmq rabbitmqctl add_user "$RABBITMQ_USER" >/dev/null
    echo "[rabbit-queue] Created user '$RABBITMQ_USER'."
fi

su-exec rabbitmq rabbitmqctl set_user_tags "$RABBITMQ_USER" administrator
su-exec rabbitmq rabbitmqctl set_permissions -p / "$RABBITMQ_USER" ".*" ".*" ".*"

# Delete default guest user if it exists for security hygiene
su-exec rabbitmq rabbitmqctl delete_user guest 2>/dev/null || true

# Prove the credentials actually work before declaring the broker ready.
# Without this the broker accepts AMQP connections (and passes a
# check_port_connectivity probe) while the broker account is still
# unauthorized, so the API Gateway receives "(530) NOT_ALLOWED - access to
# vhost '/' refused" and the audit's POST /api/billing/ returns HTTP 500 after
# the container is already reported healthy.
if su-exec rabbitmq rabbitmqctl authenticate_user "$RABBITMQ_USER" "$RABBITMQ_PASSWORD" >/dev/null 2>&1; then
    touch "${READY_SENTINEL}"
    echo "[rabbit-queue] User '$RABBITMQ_USER' verified; readiness sentinel written to ${READY_SENTINEL}."
else
    echo "[rabbit-queue] ERROR: user '$RABBITMQ_USER' could not authenticate after configuration." >&2
    exit 1
fi

echo "[rabbit-queue] RabbitMQ configuration complete. Monitoring process PID $SERVER_PID..."
wait "$SERVER_PID"
