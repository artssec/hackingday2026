#!/usr/bin/env bash
# Deja la demo "de cero": borra las alertas del Indexer, resetea el checkpoint
# de Hermes, limpia los logs del target y re-enrola el agente.
# No toca certificados, config ni .env.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

step "Borrando historial de alertas del Indexer (wazuh-alerts-*)"
CODE="$(dc exec -T wazuh.manager curl -sk -u admin:SecretPassword -o /dev/null -w '%{http_code}' \
  -X DELETE "https://wazuh.indexer:9200/wazuh-alerts-*")"
if [ "$CODE" = "200" ]; then
  info "Índices borrados (Filebeat crea uno nuevo apenas entre la próxima alerta)"
elif [ "$CODE" = "404" ]; then
  info "No había índices de alertas (ya estaba limpio)"
else
  warn "DELETE devolvió HTTP $CODE -- revisá a mano si hace falta"
fi

step "Reseteando el checkpoint de Hermes"
dc exec -T gateway-core rm -f /opt/data/wazuh-last-check.json
info "wazuh-last-check.json eliminado (la próxima corrida del cron parte de cero)"

step "Limpiando logs crudos del target (auth.log, nginx-access.log)"
dc exec -T wazuh-target sh -c ': > /var/log/auth.log; : > /var/log/nginx-access.log' 2>/dev/null || true

step "Re-enrolando el agente del target"
AGENT_ID="$(dc exec -T wazuh.manager /var/ossec/bin/agent_control -l 2>/dev/null \
  | sed -n 's/.*ID: \([0-9]*\), Name: target-endpoint.*/\1/p')"
if [ -n "$AGENT_ID" ]; then
  printf 'R\n%s\ny\n' "$AGENT_ID" | dc exec -T wazuh.manager /var/ossec/bin/manage_agents >/dev/null 2>&1 || true
fi
dc restart wazuh-target >/dev/null

info "Esperando a que el agente quede Active..."
i=0
until dc exec -T wazuh.manager /var/ossec/bin/agent_control -l 2>/dev/null | grep -q "target-endpoint.*Active"; do
  i=$((i + 1))
  [ "$i" -ge 60 ] && { warn "El agente no volvió a Active en 2 min: revisá con ./scripts/check.sh"; break; }
  sleep 2
done

step "Listo"
cat <<'EOF'
    Siguiente:
      ./scripts/check.sh
      ./scripts/demo-attack.sh
EOF
