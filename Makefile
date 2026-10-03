# =============================================================================
# cloud-design - build / run / verify helpers for the local stack.
#
#   make help    list targets
#   make up      build + start + wait until every container is healthy
#   make verify  end-to-end proof (HTTP + RabbitMQ async path + resilience)
#
# This Makefile only drives docker compose. The AWS lifecycle lives in
# terraform/ and scripts/, which are owned by a different part of the project.
# =============================================================================

COMPOSE      ?= docker compose
PROJECT      ?= cloud-design
COMPOSE_FILE ?= docker-compose.yml
ENV_FILE     ?= .env

# Host ports published by the stack (see docker-compose.yml).
GATEWAY_URL   ?= http://localhost:3000
INVENTORY_URL ?= http://localhost:8081
BILLING_URL   ?= http://localhost:8082
INV_DB_PORT   ?= 5432
BIL_DB_PORT   ?= 5433

# `up` waits for every healthcheck to pass, not merely for containers to start.
WAIT_TIMEOUT ?= 300

.DEFAULT_GOAL := help

.PHONY: help env build up up-d build-replicas ps logs down down-v \
        images stats health test smoke verify queue-drain test-py \
        py-compile shell-db shell-rabbit clean

## ---------------------------------------------------------------- setup ----

help: ## List the available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from .env.example if it does not exist (never overwrites)
	@if [ -f "$(ENV_FILE)" ]; then \
		echo "$(ENV_FILE) already exists - leaving it untouched"; \
	else \
		cp .env.example "$(ENV_FILE)" && \
		echo "created $(ENV_FILE) from .env.example (dev-only placeholder values)"; \
	fi

## ----------------------------------------------------------------- build ----

build: env ## Build all six images (contexts are one srcs/<component> each)
	$(COMPOSE) -f $(COMPOSE_FILE) build

build-replicas: env ## Report the image config each replica would use
	$(COMPOSE) -f $(COMPOSE_FILE) config

## ------------------------------------------------------------- lifecycle ----

up: env build ## Build, start and WAIT until every container reports healthy
	$(COMPOSE) -f $(COMPOSE_FILE) up -d --wait --wait-timeout $(WAIT_TIMEOUT)
	@$(MAKE) --no-print-directory ps

up-d: env ## Start without rebuilding
	$(COMPOSE) -f $(COMPOSE_FILE) up -d --wait --wait-timeout $(WAIT_TIMEOUT)

ps: ## Show container state, ports and health (the `docker ps` equivalent)
	$(COMPOSE) -f $(COMPOSE_FILE) ps

logs: ## Follow logs of every service
	$(COMPOSE) -f $(COMPOSE_FILE) logs -f --tail=100

down: ## Stop and remove the containers (volumes are kept)
	$(COMPOSE) -f $(COMPOSE_FILE) down --remove-orphans

down-v: ## Stop, remove the containers AND delete the data volumes
	$(COMPOSE) -f $(COMPOSE_FILE) down --remove-orphans --volumes

clean: down-v ## Alias for down-v

## ------------------------------------------------------------ inspection ----

health: ## One line per container: name, state and health
	@$(COMPOSE) -f $(COMPOSE_FILE) ps \
		--format 'table {{.Name}}\t{{.State}}\t{{.Status}}\t{{.Ports}}'

images: ## Measured image sizes
	@$(COMPOSE) -f $(COMPOSE_FILE) images

stats: ## Live CPU/memory per container
	$(COMPOSE) -f $(COMPOSE_FILE) stats --no-stream

shell-db: ## psql into inventory-database as the application role
	$(COMPOSE) -f $(COMPOSE_FILE) exec inventory-database \
		psql -U "$$DB_USER" -d "$$DB_NAME"

shell-rabbit: ## rabbitmqctl inside the broker
	$(COMPOSE) -f $(COMPOSE_FILE) exec rabbit-queue rabbitmqctl list_queues -p /

## ----------------------------------------------------------------- tests ----

py-compile: ## Byte-compile every Python source file (no dependencies needed)
	@python3 -m py_compile \
		srcs/api-gateway/server.py \
		srcs/api-gateway/app/__init__.py \
		srcs/api-gateway/app/proxy.py \
		srcs/api-gateway/app/queue_sender.py \
		srcs/inventory-app/server.py \
		srcs/inventory-app/app/__init__.py \
		srcs/inventory-app/app/movies.py \
		srcs/inventory-app/app/extensions.py \
		srcs/inventory-app/app/validation.py \
		srcs/billing-app/server.py \
		srcs/billing-app/app/__init__.py \
		srcs/billing-app/app/orders.py \
		srcs/billing-app/app/consume_queue.py \
		srcs/billing-app/app/validation.py \
		&& echo "all python sources compile"

test-py: py-compile ## Unit-test the dependency-free validation helpers
	cd srcs/inventory-app && python3 -m unittest discover -s tests -v
	cd srcs/billing-app && python3 -m unittest discover -s tests -v

smoke: ## HTTP-only end-to-end check through the load balancer
	echo "1. gateway health via the load balancer"
	curl -fsS $(GATEWAY_URL)/health; echo
	echo "2. create a movie"
	curl -fsS -X POST $(GATEWAY_URL)/api/movies \
		-H 'Content-Type: application/json' \
		-d '{"title":"Smoke Test Movie","year":2026}'; echo
	echo "3. list movies"
	curl -fsS $(GATEWAY_URL)/api/movies; echo
	echo "4. queue a billing order"
	curl -fsS -X POST $(GATEWAY_URL)/api/billing \
		-H 'Content-Type: application/json' \
		-d '{"user_id":"20","number_of_items":"2","total_amount":"49.99"}'; echo
	echo "5. billing consumer persisted the order?"
	sleep 5
	# Queried on billing-app directly on purpose: the gateway exposes only
	# POST /api/billing (see openapi.yaml), it does not proxy the order list.
	curl -fsS $(BILLING_URL)/orders; echo
	echo "6. liveness must stay independent of the database"
	curl -fsS $(INVENTORY_URL)/health; echo
	curl -fsS $(INVENTORY_URL)/ready; echo

queue-drain: ## Messages sitting on the durable queue right now
	@$(COMPOSE) -f $(COMPOSE_FILE) exec rabbit-queue \
		rabbitmqctl list_queues -p / name messages_ready messages_unacknowledged

test: test-py smoke ## py-compile + unit tests + HTTP smoke test (stack must be up)

verify: test queue-drain ## Full check: unit + HTTP + queue state

## ------------------------------------------------- resilience demonstration --

lb-spread: ## PROVE the load balancer distributes across both gateway replicas
	@echo "Sending 10 requests through $(GATEWAY_URL) ..."
	@for i in $$(seq 1 10); do curl -fsS -o /dev/null $(GATEWAY_URL)/health; done
	@echo "Replica chosen per request (from the load balancer's access log):"
	@$(COMPOSE) -f $(COMPOSE_FILE) logs --no-log-prefix gateway-lb \
		| grep -o 'upstream=[0-9.]*:3000' | sort | uniq -c

consumer-drain: ## PROVE the queue survives a consumer outage
	@echo "-- queue before"; $(MAKE) --no-print-directory queue-drain
	@echo "-- stopping the billing consumer"; \
		$(COMPOSE) -f $(COMPOSE_FILE) stop billing-app
	@echo "-- posting an order while NO consumer is running"; \
		curl -fsS -X POST $(GATEWAY_URL)/api/billing \
			-H 'Content-Type: application/json' \
			-d '{"user_id":"999983","number_of_items":"7","total_amount":"99.95"}' && echo
	@echo "-- queue while the consumer is down (must be >= 1)"; \
		$(MAKE) --no-print-directory queue-drain
	@echo "-- restarting the consumer"; \
		$(COMPOSE) -f $(COMPOSE_FILE) start billing-app
	@echo "-- waiting for the drain ..."; sleep 20
	@echo "-- queue after the drain (must be 0)"; \
		$(MAKE) --no-print-directory queue-drain
