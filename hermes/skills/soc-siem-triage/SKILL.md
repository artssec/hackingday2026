---
name: soc-siem-triage
description: Use for Wazuh alert follow-ups: success, IP origin, block.
category: security
version: 2
author: lab-hermes-wazuh
license: MIT
hermes:
  tags: [security, siem, wazuh, ssh, brute-force, docker]
  related_skills: []
---

# Wazuh alert triage (follow-ups en el chat)

## Cuándo usarla

El cron "Wazuh alert review" manda un resumen a este chat y el usuario
pregunta algo sobre él: ¿fue exitoso?, ¿de dónde viene la IP?, ¿qué hago?

## Reglas

- **Respondé solo lo que se preguntó**, y respetá el largo que pidan ("en 2
  líneas" = 2 líneas). Si hay algo más que valga la pena, ofrecelo en una
  sola línea al final ("¿Querés que revise el origen de la IP?"); no lo
  investigues por tu cuenta.
- Texto plano, sin encabezados, bullets ni negrita: se lee en Telegram.
- Nunca apliques un bloqueo de firewall sin que el usuario elija dónde
  (ver "Contención").
- Decí "no" cuando es "no". Con 0 éxitos, reemplazá los números por los
  reales que imprime el script. Ejemplo: "No: 12 alertas de 172.20.0.1, 0
  logins exitosos". Nunca dejes placeholders ("N", "X") en la respuesta.
- No inventes datos: si no lo viste en el aviso o en el Indexer, decilo.
- No afirmes que un origen es "externo" o "genuino" sin haberlo verificado.
  Una IP `.1` del mismo /24 que el target (ej. 172.20.0.1) es el gateway del
  bridge de Docker, o sea el host que corre los contenedores, no Internet.
  Si no vas a analizar el origen, no lo comentes.

## Cómo consultar

Las alertas viven en el **Indexer** (OpenSearch, `https://wazuh.indexer:9200`,
índices `wazuh-alerts-*`), no en la API REST del manager (puerto 55000).
Las variables `WAZUH_INDEXER_USER` / `WAZUH_INDEXER_PASSWORD` ya están en el
entorno. Cert autofirmado: `-k`.

Para no pelearte con comillas, usá el script listo (no hace falta escribir
archivos):

```bash
python3 /opt/data/scripts/wazuh-query.py --ip 172.20.0.1 --minutes 120
python3 /opt/data/scripts/wazuh-query.py --ip 172.20.0.1 --minutes 120 --success
```

Sin `--success` lista las alertas de esa IP (hora, nivel, regla, usuario); el
número del total es siempre el real (no el tope de lo listado) -- si dice
"mostrando las primeras 200", hay más de las que se imprimen, pero el total
del encabezado ya las cuenta a todas. Con `--success` cuenta solo los eventos
de login exitoso. Detalles y reglas en `references/wazuh-queries.md`.

## ¿Fue exitoso?

Éxito = reglas **5715** (sshd: authentication success) y **5501** (PAM: Login
session opened). Todo lo demás de la familia son fallos: 5503 (PAM login
failed), 5504 (usuario inválido), 5710 (usuario inexistente), 5716/5760
(sshd auth failed), 5763 (brute force). Correr `wazuh-query.py --success` y
contestar con el número.

## ¿De dónde viene la IP?

Primero comprobá que no seas vos: `hostname -i` da la IP de este contenedor
(Hermes). Si una alerta viene de esa IP, fue tu propia actividad (por ejemplo
un `ssh` de prueba al target): decilo y no recomiendes bloquearla.

`data.srcip` es la IP que vio el target; el origen real puede estar detrás de
NAT. Las alertas por defecto NO traen GeoIP: no lo prometas.

En una red Docker, una IP `.1` del mismo /24 que el target (ej. 172.20.0.1
atacando a 172.20.0.6) es el **gateway del bridge = el host que corre Docker**:
el tráfico salió de esa máquina (en el lab, casi seguro `make demo`), no de
Internet. Otras pistas de red Docker: DNS `127.0.0.11`, hostname hexadecimal,
RTT < 1 ms.

## Contención

Hay dos alcances y hay que preguntar cuál quiere:

1. En el **target** (`iptables -I INPUT -s <ip> -j DROP` dentro del
   contenedor): rápido y local, pero solo frena conexiones nuevas a ese equipo.
2. En el **host / borde de red**: corta antes de llegar al contenedor, pero lo
   ejecuta quien administra ese host.

Si la IP es el gateway del bridge (el propio host), bloquearla también corta al
host de las demás cosas del bridge: avisalo antes.

## Entorno

- Solo se puede escribir dentro de `/opt/data` (`HERMES_WRITE_SAFE_ROOT`);
  `/tmp` está denegado.
- `execute_code` a veces falla con `hermes_rpc_*.sock`: usá `terminal`.
- `iptables`/`ip`/`arp` suelen faltar en el sandbox: `ping -c1 -W1` y
  `getent hosts` dan la misma señal básica.
