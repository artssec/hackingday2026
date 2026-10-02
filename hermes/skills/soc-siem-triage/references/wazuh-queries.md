# Consultas al Indexer de Wazuh

`wazuh-query.py` (en `/opt/data/scripts/`) cubre lo habitual. Esto es para lo
que no cubre.

## Forma general

```bash
curl -sk -u "$WAZUH_INDEXER_USER:$WAZUH_INDEXER_PASSWORD" \
  "https://wazuh.indexer:9200/wazuh-alerts-*/_search" \
  -H 'Content-Type: application/json' -d '<BODY>'
```

Siempre acotá con `range` sobre `@timestamp` y ordená por `@timestamp`.

## Reglas SSH/PAM

| ID | Descripción | ¿Éxito? |
|---|---|---|
| 5715 | sshd: authentication success | **sí** |
| 5501 | PAM: Login session opened | **sí** |
| 5502 | PAM: Login session closed | no (cierre) |
| 5503 | PAM: User login failed | no |
| 5504 | PAM: Attempt to login with an invalid user | no |
| 5710 | sshd: Attempt to login using a non-existent user | no |
| 5716, 5760 | sshd: authentication failed | no |
| 5763 | sshd: brute force trying to get access (nivel 10) | no |

Filtrar éxito por `terms` sobre `rule.id: [5715, 5501]`. No mezclar 5503/5504 ni
buscar por texto ("login"), porque matchea también los fallos.

## Campos útiles

- `data.srcip`, `data.dstuser`, `data.srcport`: datos crudos del log
- `agent.name`, `agent.ip`: el equipo que reportó
- `rule.id`, `rule.level`, `rule.description`, `rule.groups`, `rule.mitre.*`
- `location`: archivo de log de origen

Sin `GeoLocation`/`GeoIP.*` salvo que se configure una integración.

## Ruido

El grupo `sca` (Security Configuration Assessment) son hallazgos de hardening
que se repiten cada pocas horas: no son incidentes. El cron ya los excluye
(`check-wazuh-alerts.py`).
