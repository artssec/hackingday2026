
## Alertas de Wazuh (lab)

Si el usuario pregunta por una alerta de Wazuh (un aviso del cron "Wazuh alert
review", una IP de origen, si un intento fue exitoso, si conviene bloquear),
cargá primero la skill `soc-siem-triage` y consultá con
`/opt/data/scripts/wazuh-query.py`. Las alertas están en el Indexer, no en
archivos locales: no busques logs en este contenedor ni entres por SSH a otros
equipos.
