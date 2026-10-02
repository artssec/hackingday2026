.PHONY: setup up init check demo replay reset down clean logs

setup:
	./scripts/setup.sh

up:
	env -u DOCKER_DEFAULT_PLATFORM docker compose up -d --build

init:
	./scripts/hermes-init.sh

check:
	./scripts/check.sh

demo:
	./scripts/demo-attack.sh

# Reprocesa las alertas de los últimos MINUTES minutos (REPLAY_MINUTES en .env,
# o: make replay MINUTES=600) y dispara el cron sin esperar
REPLAY_MINUTES := $(shell sed -n 's/^REPLAY_MINUTES=//p' .env 2>/dev/null | tail -1)
MINUTES ?= $(or $(REPLAY_MINUTES),240)
replay:
	docker compose exec -T gateway-core sh -c \
	  'printf "{\"last_timestamp\": \"%s\"}" "$$(date -u -d "$(MINUTES) minutes ago" +%Y-%m-%dT%H:%M:%S.000Z)" > /opt/data/wazuh-last-check.json'
	docker compose exec -T gateway-core hermes cron run "Wazuh alert review"

# Borra el historial de alertas y re-enrola el agente del target
reset:
	./scripts/reset-demo.sh

logs:
	docker compose logs -f gateway-core

down:
	docker compose down

clean:
	docker compose down -v
	-chmod -R u+w wazuh-src config 2>/dev/null
	rm -rf wazuh-src config hermes/data hermes/home hermes/local-share .env 2>/dev/null \
	  || sudo rm -rf wazuh-src config hermes/data hermes/home hermes/local-share .env
