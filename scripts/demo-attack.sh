#!/usr/bin/env bash
# Ataca al target del lab (SSH en 127.0.0.1:2222, web en 127.0.0.1:8443).
# Usalo solo contra tu propio contenedor.
#
#   ./scripts/demo-attack.sh          nmap + hydra (SSH) + nuclei (web)
#   ./scripts/demo-attack.sh --fim    además, modifica un archivo dentro del target
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

HOST=127.0.0.1
PORT_SSH=2222
PORT_WEB=8443

need nmap  "macOS: brew install nmap | Ubuntu/Debian: sudo apt install nmap"
need hydra "macOS: brew install hydra | Ubuntu/Debian: sudo apt install hydra"

step "Escaneo de servicios"
nmap -sV -p "$PORT_SSH,$PORT_WEB" "$HOST"

step "Fuerza bruta SSH (usuario 'demo', wordlist con $(wc -l < scripts/wordlist-demo.txt | tr -d ' ') contraseñas, ninguna acierta)"
# hydra devuelve != 0 si no encuentra credenciales
hydra -l demo -P scripts/wordlist-demo.txt -t 4 "ssh://$HOST:$PORT_SSH" || true

step "Escaneo web con nuclei (el target tiene un /.env expuesto a propósito)"
# Espera a que nginx responda antes de escanear
info "Esperando a que nginx responda en el target..."
for _ in $(seq 1 15); do
  dc exec -T wazuh-target wget -q -O /dev/null --no-check-certificate https://127.0.0.1/ 2>/dev/null && break
  sleep 1
done
# Solo plantillas exposure/misconfig, con baja concurrencia
dc --profile tools run --rm nuclei -u https://wazuh-target -tags exposure,misconfig -c 5 -retries 3 -mhe 100 || true

if [ "${1:-}" = "--fim" ]; then
  step "Modificación de archivo dentro del target (solo genera alerta si FIM lo cubre)"
  dc exec -T wazuh-target bash -c 'echo "test" >> /etc/passwd_test_file'
fi

step "Listo"
cat <<'EOF'
    Esperá 10-20 s y mirá:
      - Wazuh:    https://localhost  ->  Threat Hunting / Security Events
                  Buscá "Multiple web server 400 error codes" (regla 31151): eso es nuclei.
      - Telegram: llega en la próxima corrida del cron (cada 15 min), o forzalo:
          docker compose exec gateway-core hermes cron run "Wazuh alert review"
EOF
