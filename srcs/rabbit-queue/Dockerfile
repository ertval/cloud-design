# syntax=docker/dockerfile:1
# =============================================================================
# rabbit-queue - RabbitMQ 3.13 with the management plugin on the OFFICIAL image.
#
# The previous `FROM rabbitmq:3.13-management-alpine` + `apk add
# rabbitmq-server` combination installed a SECOND, differently-versioned broker
# next to the official one. Building ON the official management image keeps the
# broker, the management plugin and the data directory layout consistent, and
# keeps the credential/permission handling in entrypoint.sh where it can be
# verified (see the `authenticate_user` gate).
# =============================================================================
FROM rabbitmq:3.13-management-alpine

# bash: entrypoint.sh is `#!/bin/bash`; the image ships only busybox ash.
# su-exec: the entrypoint runs as root (it must chown /var/lib/rabbitmq) and
# drops to the `rabbitmq` user to start the broker.
RUN apk add --no-cache su-exec bash && \
    mkdir -p /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq && \
    chown -R rabbitmq:rabbitmq /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq

ENV RABBITMQ_DATA_DIR=/var/lib/rabbitmq \
    RABBITMQ_LOGS=/var/log/rabbitmq/rabbit.log

# COPY --chmod sets the executable bit inside this layer instead of adding a
# separate `RUN chmod +x` layer.
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# 5672 AMQP (gateway publisher + billing consumer), 15672 management UI.
EXPOSE 5672 15672

# STOPSIGNAL is SIGTERM: the official image's own graceful `rabbitmqctl stop`
# path is reused here, and entrypoint.sh traps SIGTERM/SIGINT to run it, so the
# broker closes its listeners and flushes its queue database instead of being
# SIGKILLed mid-write.

# `test -f` on the readiness sentinel is what makes this healthcheck meaningful:
# the broker answers TCP and `rabbitmq-diagnostics ping` long before the
# application user exists and its vhost permissions are granted, so without the
# sentinel the gateway could start against an unauthorized broker and every
# POST /api/billing would return HTTP 500.
HEALTHCHECK --interval=10s --timeout=10s --start-period=30s --retries=12 \
    CMD test -f /tmp/rabbit-queue-ready && rabbitmq-diagnostics -q check_running || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
