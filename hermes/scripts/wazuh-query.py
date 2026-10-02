#!/usr/bin/env python3
"""Consulta rápida al Indexer de Wazuh para el triage en el chat (skill
soc-siem-triage). Lista las alertas de una IP de origen en una ventana de
tiempo, o cuenta solo los logins exitosos.

  wazuh-query.py --ip 172.20.0.1 --minutes 120
  wazuh-query.py --ip 172.20.0.1 --minutes 120 --success
"""
import argparse
import base64
import json
import os
import ssl
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

INDEXER_URL = os.environ.get("WAZUH_INDEXER_URL", "https://wazuh.indexer:9200")
USER = os.environ["WAZUH_INDEXER_USER"]
PASSWORD = os.environ["WAZUH_INDEXER_PASSWORD"]

# Wazuh guarda las horas en UTC; solo se convierten al imprimir
LOCAL_TZ = ZoneInfo(os.environ.get("LAB_TIMEZONE", "America/Argentina/Buenos_Aires"))


def to_local(ts):
    if not ts:
        return ts
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return dt.astimezone(LOCAL_TZ).isoformat(sep=" ", timespec="seconds")

# Reglas de login exitoso: 5715 (sshd) y 5501 (PAM)
SUCCESS_RULES = ["5715", "5501"]


def search(ip, minutes, success_only, size=200):
    filters = [
        {"term": {"data.srcip": ip}},
        {"range": {"@timestamp": {"gte": f"now-{minutes}m"}}},
    ]
    if success_only:
        filters.append({"terms": {"rule.id": SUCCESS_RULES}})
    body = json.dumps({
        "size": size,
        "track_total_hits": True,
        "sort": [{"@timestamp": {"order": "asc"}}],
        "query": {"bool": {"filter": filters}},
    }).encode()
    req = urllib.request.Request(
        f"{INDEXER_URL}/wazuh-alerts-*/_search", data=body, method="POST"
    )
    creds = base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
    req.add_header("Authorization", f"Basic {creds}")
    req.add_header("Content-Type", "application/json")
    ctx = ssl._create_unverified_context()  # certificado autofirmado
    with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
        data = json.load(resp)
    return data["hits"]["total"]["value"], data["hits"]["hits"]


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--ip", required=True, help="IP de origen (data.srcip)")
    p.add_argument("--minutes", type=int, default=120, help="ventana hacia atrás")
    p.add_argument("--success", action="store_true", help="solo logins exitosos")
    args = p.parse_args()

    total, hits = search(args.ip, args.minutes, args.success)
    if args.success:
        total_all, _ = search(args.ip, args.minutes, False, size=0)
        print(f"{total} login(s) exitoso(s) de {total_all} alerta(s) desde {args.ip} "
              f"en los últimos {args.minutes} min")
    else:
        note = f" (mostrando las primeras {len(hits)})" if total > len(hits) else ""
        print(f"{total} alerta(s) desde {args.ip} en los últimos {args.minutes} min{note}")
    for h in hits:
        s = h["_source"]
        r = s.get("rule", {})
        print(
            f"{to_local(s.get('@timestamp'))} nivel {r.get('level')} regla {r.get('id')} "
            f"usuario {s.get('data', {}).get('dstuser') or '-'}: {r.get('description')}"
        )


if __name__ == "__main__":
    main()
