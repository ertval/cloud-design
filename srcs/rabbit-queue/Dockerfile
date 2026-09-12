# syntax=docker/dockerfile:1
# Base image: Alpine 3.23 (penultimate stable release)
FROM alpine:3.23

RUN apk add --no-cache \
    bash \
    su-exec \
    rabbitmq-server \
    && mkdir -p /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq \
    && chown -R rabbitmq:rabbitmq /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq \
    && rabbitmq-plugins enable --offline rabbitmq_management

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 5672 15672

HEALTHCHECK --interval=10s --timeout=10s --start-period=60s --retries=15 \
    CMD rabbitmq-diagnostics -q ping || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

