#!/usr/bin/env bash
# Funciones compartidas por los scripts del lab.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_G" "$C_0" "$C_B" "$*" "$C_0"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Falta '$1'. ${2:-}"; }

# Lee una clave de .env
env_get() {
  [ -f "$ROOT/.env" ] || return 0
  grep -E "^$1=" "$ROOT/.env" | head -1 | cut -d= -f2-
}

# Usa sudo solo si el daemon no responde sin él
if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif sudo docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
else
  DOCKER=(docker)
fi

# docker compose ignorando DOCKER_DEFAULT_PLATFORM
dc() { env -u DOCKER_DEFAULT_PLATFORM "${DOCKER[@]}" compose "$@"; }

# En Linux los certificados los genera root
FS_SUDO=""
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" != "0" ]; then FS_SUDO="sudo"; fi

WAZUH_VERSION="$(env_get WAZUH_VERSION)"
WAZUH_VERSION="${WAZUH_VERSION:-4.14.8}"
