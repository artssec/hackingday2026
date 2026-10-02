#!/usr/bin/env bash
# Verifica que el lab esté funcionando. Sale con código != 0 si algo falla.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

FAILS=0
ok()   { printf '  %s[ok]%s   %s\n' "$C_G" "$C_0" "$*"; }
fail() { printf '  %s[FAIL]%s %s\n' "$C_R" "$C_0" "$*"; FAILS=$((FAILS+1)); }
skip() { printf '  %s[skip]%s %s\n' "$C_Y" "$C_0" "$*"; }

step "Contenedores"
RUNNING="$("${DOCKER[@]}" ps --format '{{.Names}}')"
for svc in wazuh.manager wazuh.indexer wazuh.dashboard wazuh-target docker-socket-proxy gateway-core; do
  if printf '%s\n' "$RUNNING" | grep -q "$svc"; then ok "$svc corriendo"; else fail "$svc NO está corriendo"; fi
done

step "Indexer (OpenSearch)"
HEALTH="$(dc exec -T wazuh.manager curl -sk -u admin:SecretPassword https://wazuh.indexer:9200/_cluster/health 2>/dev/null || true)"
case "$HEALTH" in
  *'"status":"green"'*|*'"status":"yellow"'*) ok "cluster health: $(printf '%s' "$HEALTH" | sed -E 's/.*"status":"([a-z]+)".*/\1/')" ;;
  *) fail "el indexer no responde o está en red" ;;
esac

step "Agente del target registrado en el manager"
AGENTS="$(dc exec -T wazuh.manager /var/ossec/bin/agent_control -l 2>/dev/null || true)"
if printf '%s' "$AGENTS" | grep -q "target-endpoint"; then
  if printf '%s' "$AGENTS" | grep "target-endpoint" | grep -q "Active"; then ok "target-endpoint: Active"; else fail "target-endpoint registrado pero no Active (si recién levantaste el stack, esperá ~1 min y repetí)"; fi
else
  fail "target-endpoint no aparece en agent_control -l"
fi

step "Sitio de ejemplo (nginx) en el target"
if dc exec -T wazuh-target wget -q -O /dev/null --no-check-certificate https://127.0.0.1/ 2>/dev/null; then
  ok "https://127.0.0.1 (dentro de wazuh-target) responde"
else
  fail "nginx no responde dentro de wazuh-target -- ver 'docker compose logs wazuh-target'"
fi

step "Escaneo de vulnerabilidades desactivado"
if dc exec -T wazuh.manager sed -n '/<vulnerability-detection>/,/<\/vulnerability-detection>/p' /var/ossec/etc/ossec.conf 2>/dev/null \
  | grep -q '<enabled>no</enabled>'; then
  ok "vulnerability-detection enabled=no"
else
  fail "sigue activo: corré ./scripts/disable-vuln-detection.sh"
fi

step "Hermes"
if curl -fsS http://127.0.0.1:8642/health >/dev/null 2>&1; then ok "API en :8642 responde"; else fail "http://127.0.0.1:8642/health no responde"; fi
if dc exec -T gateway-core hermes auth status opencode-go >/dev/null 2>&1; then ok "credencial opencode-go cargada"; else fail "falta credencial: ./scripts/hermes-init.sh"; fi
if dc exec -T gateway-core hermes cron list 2>/dev/null | grep -q "Wazuh alert review"; then ok "cron 'Wazuh alert review' creado"; else fail "falta el cron: ./scripts/hermes-init.sh"; fi

step "Script de alertas (corrida real contra el indexer)"
if dc exec -T gateway-core bash -c 'set -a; . /opt/data/.env; set +a; python3 /opt/data/scripts/check-wazuh-alerts.py' >/dev/null 2>"$ROOT/.check-stderr"; then
  ok "check-wazuh-alerts.py corre sin errores"
else
  fail "check-wazuh-alerts.py falló: $(head -c 300 "$ROOT/.check-stderr")"
fi
rm -f "$ROOT/.check-stderr"

printf '\n'
if [ "$FAILS" -eq 0 ]; then
  printf '%sTodo OK.%s Siguiente: ./scripts/demo-attack.sh\n' "$C_G" "$C_0"
else
  printf '%s%d chequeo(s) fallaron.%s\n' "$C_R" "$FAILS" "$C_0"
  exit 1
fi
