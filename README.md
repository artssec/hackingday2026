# Del caos de logs al control total — Wazuh + Hermes

Laboratorio de la charla **"Del caos de logs al control total"**, presentada en
**Hacking Day 2026 (Paraná, Entre Ríos)**.

La idea: Wazuh (SIEM) genera alertas de seguridad, y
[Hermes](https://github.com/NousResearch/hermes-agent) (agente de IA) las lee
cada 15 minutos con **MiniMax M3** (vía OpenCode Go) y manda un resumen humano a
**Telegram** — en vez de que alguien tenga que mirar el dashboard todo el día.
Después podés contestarle en el chat ("¿de dónde viene esa IP?") y sigue
investigando por vos.

Todo corre en contenedores descartables, en tu propia máquina, y nada queda
expuesto fuera de `127.0.0.1`.

> **Aviso:** el contenedor `wazuh-target` es vulnerable **a propósito** (SSH con
> contraseña débil y un `/.env` servido por nginx, con credenciales falsas) y
> `make demo` lo ataca con `nmap`, `hydra` y `nuclei`. Es solo para usar contra
> tu propio lab local: nunca apuntes esas herramientas a algo que no sea tuyo, y
> no publiques el target en una red real.

## Qué arma este repo

```
Internet -----X (nada expuesto salvo 127.0.0.1)

┌─────────────────────────── labnet (red docker) ───────────────────────────┐
│                                                                             │
│  wazuh-target (ssh cred. débil +  →  wazuh.manager  →  wazuh.indexer       │
│  nginx con .env expuesto, ambos                                           │
│  a propósito)                                                             │
│                                            │                 ↑             │
│                                            │          wazuh.dashboard      │
│                                            │           (https://localhost) │
│                                            │                               │
│                                    gateway-core (Hermes)                   │
│                                    cron cada 15' → lee indexer             │
│                                    → MiniMax M3 (OpenCode Go)              │
│                                    → Telegram                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **wazuh.manager / wazuh.indexer / wazuh.dashboard** — stack oficial de Wazuh
  (single-node), instalado desde el repo `wazuh-docker` (no viene versionado
  acá: lo clona `setup.sh`, pineado a la versión de `.env`).
- **wazuh-target** — Ubuntu con `sshd`, nginx y un agente de Wazuh, pensado
  para ser atacado. Usuario SSH `demo` / contraseña `demo123`, y un `/.env`
  expuesto (credenciales falsas) en el sitio de nginx, ambos a propósito.
  Los dos viven en el mismo contenedor (con el mismo agente) para que el
  escaneo web quede tan visible para Wazuh como el brute-force SSH -- si
  nginx viviera en otro contenedor sin agente, ese tráfico sería invisible
  para el SIEM.
- **gateway-core** — Hermes, imagen oficial `nousresearch/hermes-agent`
  pineada por versión y digest. Corre un cron job en modo agente: un script
  consulta el indexer directo (no la API REST del manager) y filtra el ruido;
  Hermes interpreta lo que queda y manda el resumen a Telegram.
- **docker-socket-proxy** — Hermes puede ejecutar código; en vez de darle el
  socket de Docker del host directo, pasa por un proxy de solo lectura+creación
  acotada. Es la única razón por la que el socket aparece en este compose.

## Estructura del repo

```
docker-compose.yml        stack completo (Wazuh, target, Hermes, socket-proxy, nuclei)
Makefile                  atajos: setup / up / init / check / demo / replay / reset / clean
scripts/                  setup, init de Hermes, checks, demo de ataque, reset
hermes/scripts/           scripts que usa el cron (consulta al indexer y filtra el ruido)
hermes/skills/            skill de triage de Wazuh para las preguntas de seguimiento
hermes/templates/         config.yaml y SOUL.md que carga hermes-init.sh
target/                   contenedor atacable (sshd + nginx + agente de Wazuh)
```

## Requisitos

- macOS (Docker Desktop o Colima) o Linux (Ubuntu/Debian), con Docker y `docker compose` v2.
- **8 GB de RAM asignados a Docker** como mínimo (Wazuh Indexer es un
  OpenSearch completo). En Docker Desktop: *Settings → Resources → Memory*.
  En Colima: ver abajo.
- `git`, `curl`, `openssl`, `perl` (en macOS vienen instalados).
- `nmap` y `hydra` para la demo de ataque (`brew install nmap hydra` o `sudo apt install nmap hydra`).
  `nuclei` no hace falta instalarlo: corre en un contenedor (`projectdiscovery/nuclei`)
  levantado por el propio `docker compose`.
- Una cuenta de [OpenCode Go](https://opencode.ai) (no la API de pago por uso)
  y un bot de Telegram nuevo (`/newbot` con [@BotFather](https://t.me/BotFather)).

### Linux (Ubuntu/Debian)

```bash
sudo apt install git curl openssl perl nmap hydra
sudo apt install docker-compose-v2 docker.io   # o Docker Engine desde docs.docker.com
```

### Apple Silicon (M1/M2/M3/M4/M5)

Desde Wazuh 4.14.7 las imágenes tienen build arm64 nativo, así que todo corre
sin emulación. No exportes `DOCKER_DEFAULT_PLATFORM=linux/amd64`: si corrés
`docker compose` a mano, hacé antes `unset DOCKER_DEFAULT_PLATFORM`
(`make up` ya lo ignora).

### Colima (en vez de Docker Desktop)

1. **`docker compose` no aparece** (`[x] Falta el plugin 'docker compose'`):
   con el `docker` de Homebrew, el plugin se instala en
   `/opt/homebrew/lib/docker/cli-plugins` pero Docker no lo busca ahí.
   Agregalo a `~/.docker/config.json`:
   ```json
   "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]
   ```
   Verificá con `docker compose version`.
2. **RAM y CPU**: la VM por default de Colima tiene 2 GB. Un
   `stop`/`start` cambia los recursos **sin borrar** contenedores, imágenes
   ni volúmenes de otros proyectos (no uses `colima delete`, eso sí borra
   todo):
   ```bash
   colima stop
   colima start --cpu 4 --memory 8
   colima list   # tiene que mostrar 4 CPUs / 8GiB
   ```
3. **Volver a como estaba** después de usar el lab (la VM no le devuelve la
   RAM a macOS hasta reiniciarla):
   ```bash
   make down
   colima stop
   colima start --cpu 2 --memory 2
   ```
   Si después volvés a levantar el lab, corré `make setup` de nuevo: el
   reinicio de la VM pierde `vm.max_map_count`.

## Uso

```bash
git clone https://github.com/artssec/hackingday2026.git && cd hackingday2026
cp .env.example .env
vim .env   # completá OPENCODE_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_USER_ID

make setup   # clona wazuh-docker, genera certs, prepara ./hermes/data
make up      # docker compose up -d --build (primer arranque: varios minutos)
make init    # carga la key de OpenCode en Hermes + crea el cron job
make check   # valida que todo esté vivo, contenedor por contenedor
```

Con `make check` en verde, generá tráfico y esperá el resumen en Telegram:

```bash
make demo    # nmap + fuerza bruta SSH + nuclei contra el .env expuesto del target
```

El cron corre cada 15 minutos; para no esperar en vivo durante la charla:

```bash
docker compose exec gateway-core hermes cron run "Wazuh alert review"
```

Si el marcador de "última revisión" ya está al día, ese comando no manda nada
(no hay alertas nuevas). Para reprocesar las de las últimas horas y disparar el
job de una: `make replay`. La ventana (240 min por defecto) se cambia con
`REPLAY_MINUTES` en el `.env`, o puntual con `make replay MINUTES=600`. Si la
ráfaga es más vieja que la ventana, el job sale silencioso: subí la ventana o
usá `make demo` para generar una nueva.

Silencio en Telegram = no hubo nada fuera de ruido de compliance/SCA, o el
agente juzgó que no valía aviso (`[SILENT]`): es el comportamiento esperado,
no un fallo.

Como el resumen lo genera el propio Hermes y `cron.mirror_delivery` está
activo, queda en el contexto del chat: podés responderle en Telegram
("dame más info", "¿de dónde viene esa IP?") y sabe de qué le hablás. Ojo: el
mirror necesita que ya hayas escrito al bot alguna vez (sesión abierta).

## Accesos

| Servicio | URL | Usuario |
|---|---|---|
| Wazuh dashboard | https://localhost | `admin` / `SecretPassword` |
| Hermes dashboard | http://127.0.0.1:9119 | `admin` / (ver `.env`, `DASHBOARD_PASSWORD`) |
| Target (SSH) | `ssh demo@127.0.0.1 -p 2222` | `demo` / `demo123` |
| Target (sitio de ejemplo) | https://127.0.0.1:8443 (cert autofirmado) | — |

Todas las credenciales son las de ejemplo del propio Wazuh o generadas random
por `setup.sh` — quedan en tu `.env` local, que nunca se sube (ver `.gitignore`).

## Decisiones de diseño

- **Cron en modo agente**: un script consulta el indexer y filtra en Python
  (si no hay nada nuevo imprime `{"wakeAgent": false}` y Hermes no despierta al
  LLM). El agente redacta el resumen y responde `[SILENT]` si no hay nada que
  avisar. Así el aviso queda en el contexto del chat y se le puede responder.
- **Skill de triage** (`hermes/skills/soc-siem-triage/`): para las preguntas de
  seguimiento en el chat. Trae las reglas de Wazuh y un script de consulta
  (`wazuh-query.py`). `hermes-init.sh` también agrega una instrucción a
  `SOUL.md` (`hermes/templates/SOUL-wazuh.md`) para que el agente la use.
- **Indexer y no la API REST del manager**: las alertas (`wazuh-alerts-*`)
  viven en el indexer (OpenSearch).
- **`docker-socket-proxy`**: Hermes puede ejecutar comandos; en vez de darle el
  socket de Docker del host, pasa por un proxy con permisos acotados.

## Arrancar la demo sin historial viejo

`make demo` (y probar cosas en general) deja alertas de sobra en el Indexer.
Para empezar de cero sin tener que reconstruir nada:

```bash
make reset   # borra el historial de alertas, resetea el checkpoint de Hermes
             # y re-enrola el agente del target -- deja certs/config/.env intactos
```

Es rápido (no reconstruye imágenes) y podés correrlo las veces que haga falta
entre demos. Para un reset completo (recertificar, reclonar wazuh-docker,
etc.) usá `make clean` de abajo.

## Limpiar todo

```bash
make clean   # docker compose down -v + borra wazuh-src, config, hermes/data, .env
```
