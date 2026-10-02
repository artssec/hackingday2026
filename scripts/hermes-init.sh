#!/usr/bin/env bash
# Corre después de `docker compose up`: carga la credencial de OpenCode Go en
# Hermes y crea el cron job de revisión de alertas. Se puede repetir.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

JOB_NAME="Wazuh alert review"
KEY="$(env_get OPENCODE_API_KEY)"
[ -n "$KEY" ] || die "OPENCODE_API_KEY está vacío en .env"

RUNNING="$("${DOCKER[@]}" ps --format '{{.Names}}')"
printf '%s\n' "$RUNNING" | grep -qx gateway-core \
  || die "gateway-core no está corriendo. Primero: docker compose up -d --build"

step "Esperando a que Hermes responda"
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8642/health >/dev/null 2>&1; then break; fi
  [ "$i" = 30 ] && die "Hermes no respondió en http://127.0.0.1:8642/health (mirá: docker compose logs gateway-core)"
  sleep 2
done
info "Hermes OK"

step "Cargando credencial de opencode-go"
dc exec -T gateway-core hermes auth add opencode-go --api-key "$KEY"
dc exec -T gateway-core hermes auth status opencode-go

step "Config: el aviso del cron queda en el contexto del chat"
dc exec -T gateway-core hermes config set cron.mirror_delivery true

step "Instrucción para usar la skill de triage"
if dc exec -T gateway-core grep -q "^## Alertas de Wazuh" /opt/data/SOUL.md 2>/dev/null; then
  info "SOUL.md ya tiene la instrucción"
else
  dc exec -T gateway-core sh -c 'cat >> /opt/data/SOUL.md' < hermes/templates/SOUL-wazuh.md
  info "Instrucción agregada a SOUL.md"
fi

step "Cron job '$JOB_NAME' (cada 15 min, modo agente, entrega a Telegram)"
PROMPT='Sos un analista de seguridad revisando alertas de Wazuh, ya filtradas de ruido de compliance (arriba, en Script Output). Interpretalas con criterio: priorizá patrones como múltiples intentos fallidos de SSH del mismo origen (fuerza bruta), escaneos de puertos, o modificación de archivos críticos. Este resumen se lee en un chat de Telegram, en vivo, durante una charla -- NO es un informe. Máximo 5-6 líneas de texto en total, DIVIDIDAS en 3 párrafos cortos separados por un renglón en blanco:
1) Qué pasó y de dónde (1-2 líneas).
2) Contexto relevante si lo hay -- otra alerta cercana en el tiempo, algo llamativo (1-2 líneas, opcional, omitilo si no suma).
3) Una sola recomendación concreta (1 línea).
Sin subtítulos, sin bullets, sin negrita -- solo texto plano en esos 3 bloques. No repitas el JSON crudo ni muestres tu razonamiento. Basate SOLO en las alertas del Script Output (usá los IDs de regla y las horas exactas que figuran ahí tal cual: ya vienen en hora local de Argentina, NO en UTC -- no les agregues "UTC" vos ni las conviertas; nada de "hace X segundos"); no inventes datos. Si una alerta está marcada [IP del propio Hermes], no es un ataque externo: aclaralo y no recomiendes bloquearla. Escribí solo en español. Si no hay nada realmente accionable, respondé exactamente [SILENT].'

# Si el job ya existe, se recrea
OLD_ID="$(dc exec -T gateway-core hermes cron list 2>/dev/null \
  | awk -v n="$JOB_NAME" '/^  [0-9a-f]+ \[/ {id=$1} $1=="Name:" && substr($0, index($0,$2))==n {print id; exit}')"
if [ -n "$OLD_ID" ]; then
  info "Ya existe ($OLD_ID): se recrea"
  dc exec -T gateway-core hermes cron remove "$OLD_ID"
fi
dc exec -T gateway-core hermes cron create "*/15 * * * *" "$PROMPT" \
  --script check-wazuh-alerts.py \
  --name "$JOB_NAME" \
  --deliver telegram

step "Listo"
cat <<EOF
    Disparo manual : docker compose exec gateway-core hermes cron run "$JOB_NAME"
    Ver corridas   : docker compose exec gateway-core hermes cron runs "$JOB_NAME"
EOF
