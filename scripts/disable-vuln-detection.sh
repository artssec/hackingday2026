#!/usr/bin/env bash
# Desactiva vulnerability-detection en el ossec.conf del manager en ejecución.
# Sirve si el stack ya estaba levantado cuando corriste setup.sh.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

step "Editando /var/ossec/etc/ossec.conf dentro del contenedor"
dc exec -T wazuh.manager sed -i \
  '/<vulnerability-detection>/,/<\/vulnerability-detection>/ s/<enabled>yes<\/enabled>/<enabled>no<\/enabled>/' \
  /var/ossec/etc/ossec.conf
dc exec -T wazuh.manager grep -A 4 "<vulnerability-detection>" /var/ossec/etc/ossec.conf

step "Reiniciando wazuh.manager"
dc restart wazuh.manager
info "Listo"
