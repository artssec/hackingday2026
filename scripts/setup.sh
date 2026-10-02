#!/usr/bin/env bash
# Prepara lo que necesita docker-compose.yml:
#   - .env con secretos random
#   - copia local de wazuh-docker y ./config
#   - certificados del indexer
#   - escaneo de vulnerabilidades del manager desactivado
#   - vm.max_map_count para el indexer
#   - ./hermes/data (config, .env, scripts y skill)
# Se puede correr las veces que haga falta.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

OS="$(uname -s)"
ARCH="$(uname -m)"

# --------------------------------------------------------------------------
step "1/7 Chequeando requisitos"
need docker "Instalá Docker Desktop (macOS) o Docker Engine (Linux)."
need git
need openssl
need curl
need perl
dc version >/dev/null 2>&1 || die "Falta el plugin 'docker compose' (v2)."
"${DOCKER[@]}" info >/dev/null 2>&1 || die "El daemon de Docker no responde. ¿Abriste Docker Desktop?"

MEM_BYTES="$("${DOCKER[@]}" info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
if [ "${MEM_BYTES:-0}" -lt 7000000000 ] 2>/dev/null; then
  warn "Docker tiene menos de ~7 GB de RAM asignada. Wazuh pide 8 GB para single-node."
  warn "En Docker Desktop: Settings > Resources > Memory (subilo a 8 GB o más)."
fi
info "docker OK ($(dc version --short 2>/dev/null || echo compose v2)) - sistema: $OS/$ARCH"

if [ -n "${DOCKER_DEFAULT_PLATFORM:-}" ]; then
  warn "DOCKER_DEFAULT_PLATFORM=$DOCKER_DEFAULT_PLATFORM fuerza esa plataforma en todos los contenedores."
  warn "'make up' lo ignora; si usás docker compose a mano: unset DOCKER_DEFAULT_PLATFORM"
fi

# --------------------------------------------------------------------------
step "2/7 Archivo .env"
if [ ! -f .env ]; then
  cp .env.example .env
  info "Creado .env a partir de .env.example"
fi

# Completa la clave solo si está vacía
fill_if_empty() {
  local key="$1" val="$2"
  if grep -Eq "^${key}=$" .env; then
    K="$key" V="$val" perl -pi -e 's/^\Q$ENV{K}\E=$/$ENV{K}=$ENV{V}/' .env
    info "Generado $key"
  fi
}
fill_if_empty DASHBOARD_PASSWORD "$(openssl rand -hex 12)"
fill_if_empty DASHBOARD_SECRET   "$(openssl rand -hex 24)"
fill_if_empty API_SERVER_KEY     "$(openssl rand -hex 24)"

WAZUH_VERSION="$(env_get WAZUH_VERSION)"; WAZUH_VERSION="${WAZUH_VERSION:-4.14.8}"
LAB_TIMEZONE="$(env_get LAB_TIMEZONE)"; LAB_TIMEZONE="${LAB_TIMEZONE:-America/Argentina/Buenos_Aires}"

# --------------------------------------------------------------------------
step "3/7 Código base de Wazuh (wazuh-docker v$WAZUH_VERSION)"
if [ ! -d wazuh-src ]; then
  git clone --depth 1 -b "v$WAZUH_VERSION" https://github.com/wazuh/wazuh-docker.git wazuh-src
else
  info "wazuh-src ya existe, se reutiliza"
fi

if [ ! -d config ]; then
  cp -R wazuh-src/single-node/config config
  info "Copiado wazuh-src/single-node/config -> config"
fi

for f in \
  config/wazuh_cluster/wazuh_manager.conf \
  config/wazuh_indexer/wazuh.indexer.yml \
  config/wazuh_indexer/internal_users.yml \
  config/wazuh_dashboard/opensearch_dashboards.yml \
  config/wazuh_dashboard/wazuh.yml; do
  [ -f "$f" ] || die "Falta $f. ¿Cambió la estructura de wazuh-docker en v$WAZUH_VERSION?"
done

# Zona horaria fija en el dashboard
DASH_CONF="config/wazuh_dashboard/opensearch_dashboards.yml"
if ! grep -q "^uiSettings.overrides.dateFormat:tz:" "$DASH_CONF"; then
  echo "uiSettings.overrides.dateFormat:tz: \"$LAB_TIMEZONE\"" >> "$DASH_CONF"
  info "Dashboard fijado a $LAB_TIMEZONE en $DASH_CONF"
fi

# --------------------------------------------------------------------------
step "4/7 Certificados del indexer"
CERT_DIR="config/wazuh_indexer_ssl_certs"
CERTS="root-ca.pem root-ca-manager.pem admin.pem admin-key.pem \
wazuh.indexer.pem wazuh.indexer-key.pem wazuh.manager.pem wazuh.manager-key.pem \
wazuh.dashboard.pem wazuh.dashboard-key.pem"

certs_ok() {
  local c
  for c in $CERTS; do $FS_SUDO test -f "$CERT_DIR/$c" || return 1; done
}

if certs_ok; then
  info "Certificados ya generados"
else
  SRC_CERTS="wazuh-src/single-node/config/wazuh_indexer_ssl_certs"
  # Borra restos de una corrida anterior
  if [ -d "$SRC_CERTS" ]; then
    $FS_SUDO chmod -R u+w "$SRC_CERTS"
    $FS_SUDO rm -rf "$SRC_CERTS"
  fi
  # Se corre desde wazuh-src/single-node para que los certs queden ahí
  ( cd wazuh-src/single-node && dc -f generate-indexer-certs.yml run --rm generator )
  # En macOS con Colima el generador no puede crear root-ca-manager.*: se copian acá
  if [ ! -f "$SRC_CERTS/root-ca-manager.pem" ] && [ -f "$SRC_CERTS/root-ca.pem" ]; then
    $FS_SUDO chmod u+w "$SRC_CERTS"
    $FS_SUDO cp -p "$SRC_CERTS/root-ca.pem" "$SRC_CERTS/root-ca-manager.pem"
    $FS_SUDO cp -p "$SRC_CERTS/root-ca.key" "$SRC_CERTS/root-ca-manager.key"
    $FS_SUDO chmod u-w "$SRC_CERTS"
    info "root-ca-manager.* creados"
  fi
  if [ -d "$CERT_DIR" ]; then $FS_SUDO chmod -R u+w "$CERT_DIR"; fi
  $FS_SUDO rm -rf "$CERT_DIR"
  # cp -a preserva el dueño de los archivos
  $FS_SUDO cp -a wazuh-src/single-node/config/wazuh_indexer_ssl_certs "$CERT_DIR"
  certs_ok || die "No se generaron todos los certificados esperados en $CERT_DIR"
  info "Certificados generados y copiados a $CERT_DIR"
fi

# --------------------------------------------------------------------------
step "5/7 Desactivando escaneo de vulnerabilidades del manager"
# Si el stack ya estaba levantado, usá scripts/disable-vuln-detection.sh
CONF="config/wazuh_cluster/wazuh_manager.conf"
perl -0pi -e 's{(<vulnerability-detection>\s*<enabled>)yes(</enabled>)}{${1}no${2}}s' "$CONF"
if perl -0ne 'exit(!/<vulnerability-detection>\s*<enabled>no<\/enabled>/s)' "$CONF"; then
  info "vulnerability-detection: enabled=no en $CONF"
else
  warn "No pude confirmar que vulnerability-detection quedó en 'no' en $CONF. Revisalo a mano."
fi

# --------------------------------------------------------------------------
step "6/7 vm.max_map_count (lo pide el indexer)"
WANT=262144
if [ "$OS" = "Linux" ]; then
  CUR="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if [ "$CUR" -lt "$WANT" ]; then
    sudo sysctl -w vm.max_map_count=$WANT
    warn "No persiste al reiniciar. Para dejarlo fijo: echo 'vm.max_map_count=$WANT' | sudo tee /etc/sysctl.d/99-wazuh.conf"
  else
    info "vm.max_map_count=$CUR OK"
  fi
else
  # En macOS el valor vive en la VM de Docker
  CUR="$("${DOCKER[@]}" run --rm --privileged alpine:3 sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if [ "${CUR:-0}" -lt "$WANT" ]; then
    "${DOCKER[@]}" run --rm --privileged alpine:3 sysctl -w vm.max_map_count=$WANT
    warn "El valor se pierde si la VM de Docker se reinicia: si el indexer no arranca, repetí este setup."
  else
    info "vm.max_map_count=$CUR (VM de Docker) OK"
  fi
fi

# --------------------------------------------------------------------------
step "7/7 Estado de Hermes (./hermes/data)"
mkdir -p hermes/data/scripts hermes/home hermes/local-share

# Se copian (no symlink): Hermes no sigue symlinks fuera de su carpeta de scripts
cp hermes/scripts/check-wazuh-alerts.py hermes/data/scripts/check-wazuh-alerts.py
cp hermes/scripts/wazuh-query.py hermes/data/scripts/wazuh-query.py
chmod +x hermes/data/scripts/check-wazuh-alerts.py hermes/data/scripts/wazuh-query.py
info "Scripts de alertas copiados a hermes/data/scripts/"

# Skill de triage
rm -rf hermes/data/skills/soc-siem-triage
mkdir -p hermes/data/skills
cp -R hermes/skills/soc-siem-triage hermes/data/skills/soc-siem-triage
info "Skill soc-siem-triage copiada a hermes/data/skills/"

if [ ! -f hermes/data/config.yaml ]; then
  cp hermes/templates/config.yaml hermes/data/config.yaml
  info "Creado hermes/data/config.yaml (opencode-go / minimax-m3)"
fi

# Permisos en Linux: el contenedor corre con UID 10000
if [ "$OS" = "Linux" ]; then
  if command -v setfacl >/dev/null 2>&1; then
    for d in hermes/data hermes/home hermes/local-share; do
      $FS_SUDO setfacl -R -m "u:10000:rwX,u:$(id -u):rwX" "$d"
      $FS_SUDO setfacl -R -d -m "u:10000:rwX,u:$(id -u):rwX" "$d"
    done
    info "ACLs aplicadas (UID 10000 + tu usuario, con herencia)"
  else
    warn "No hay setfacl (paquete 'acl'): se usa chmod a+rwX."
    $FS_SUDO chmod -R a+rwX hermes/data hermes/home hermes/local-share
  fi
fi

# hermes/data/.env se genera desde el .env de la raíz
MISSING=""
OPENCODE_API_KEY="$(env_get OPENCODE_API_KEY)"
TELEGRAM_BOT_TOKEN="$(env_get TELEGRAM_BOT_TOKEN)"
TELEGRAM_USER_ID="$(env_get TELEGRAM_USER_ID)"
WAZUH_MIN_LEVEL="$(env_get WAZUH_MIN_LEVEL)"; WAZUH_MIN_LEVEL="${WAZUH_MIN_LEVEL:-5}"
[ -n "$OPENCODE_API_KEY" ]   || MISSING="$MISSING OPENCODE_API_KEY"
[ -n "$TELEGRAM_BOT_TOKEN" ] || MISSING="$MISSING TELEGRAM_BOT_TOKEN"
[ -n "$TELEGRAM_USER_ID" ]   || MISSING="$MISSING TELEGRAM_USER_ID"

if [ -n "$MISSING" ]; then
  warn "Faltan valores en .env:$MISSING"
  warn "Completalos en .env y volvé a correr ./scripts/setup.sh"
  exit 1
fi

cat > hermes/data/.env <<EOF
# Generado por scripts/setup.sh a partir del .env de la raíz
OPENAI_API_KEY=$OPENCODE_API_KEY
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ALLOWED_USERS=$TELEGRAM_USER_ID
TELEGRAM_HOME_CHANNEL=$TELEGRAM_USER_ID

# Para los scripts de alertas
WAZUH_INDEXER_URL=https://wazuh.indexer:9200
WAZUH_INDEXER_USER=admin
WAZUH_INDEXER_PASSWORD=SecretPassword
WAZUH_MIN_LEVEL=$WAZUH_MIN_LEVEL
LAB_TIMEZONE=$LAB_TIMEZONE
EOF
info "Generado hermes/data/.env"

step "Listo"
DASH_PASS="$(env_get DASHBOARD_PASSWORD)"
cat <<EOF
    Siguiente:
      1) docker compose up -d --build          (o: make up)
      2) ./scripts/hermes-init.sh              (carga la key de OpenCode y crea el cron)
      3) ./scripts/check.sh                    (verifica que todo esté vivo)

    Wazuh dashboard : https://localhost        (admin / SecretPassword)
    Hermes dashboard: http://127.0.0.1:9119/login   (admin / $DASH_PASS)
EOF
