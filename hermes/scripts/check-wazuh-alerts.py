#!/usr/bin/env python3
"""Trae las alertas nuevas de Wazuh desde la última corrida, consultando el
Indexer (wazuh-alerts-*), y las imprime agrupadas por regla, agente e IP de
origen. Es el script del cron de Hermes. Si no hay nada nuevo imprime
{"wakeAgent": false} y Hermes no despierta al agente."""
import base64
import json
import os
import socket
import ssl
import sys
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

INDEXER_URL = os.environ.get("WAZUH_INDEXER_URL", "https://wazuh.indexer:9200")
INDEXER_USER = os.environ["WAZUH_INDEXER_USER"]
INDEXER_PASSWORD = os.environ["WAZUH_INDEXER_PASSWORD"]
MIN_LEVEL = int(os.environ.get("WAZUH_MIN_LEVEL", "7"))
MARKER_PATH = "/opt/data/wazuh-last-check.json"
INDEX_PATTERN = "wazuh-alerts-*"
MAX_GROUPS = 200  # tope de grupos (regla, agente, ip) por corrida

# Wazuh guarda las horas en UTC; solo se convierten al imprimir
LOCAL_TZ = ZoneInfo(os.environ.get("LAB_TIMEZONE", "America/Argentina/Buenos_Aires"))


def to_local(ts):
    if not ts:
        return ts
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return dt.astimezone(LOCAL_TZ).isoformat(sep=" ", timespec="seconds")

# Grupos de reglas que se ignoran (compliance)
NOISY_GROUPS = {"sca"}

# IP de este contenedor, para no confundirla con un atacante externo
try:
    OWN_IP = socket.gethostbyname(socket.gethostname())
except OSError:
    OWN_IP = None

# El Indexer usa un certificado autofirmado
CTX = ssl._create_unverified_context()


def load_last_check():
    if os.path.exists(MARKER_PATH):
        with open(MARKER_PATH) as f:
            return json.load(f).get("last_timestamp")
    return None


def save_last_check(ts):
    with open(MARKER_PATH, "w") as f:
        json.dump({"last_timestamp": ts}, f)


def search_alerts(last_ts):
    filters = [{"range": {"rule.level": {"gte": MIN_LEVEL}}}]
    if last_ts:
        filters.append({"range": {"@timestamp": {"gt": last_ts}}})

    # "newest" define el próximo checkpoint; "groups" agrupa por regla+agente+ip
    body = json.dumps({
        "size": 0,
        "query": {"bool": {"filter": filters}},
        "aggs": {
            "newest": {"max": {"field": "@timestamp"}},
            "groups": {
                "composite": {
                    "size": MAX_GROUPS,
                    "sources": [
                        {"rule_id": {"terms": {"field": "rule.id"}}},
                        {"agent": {"terms": {"field": "agent.name"}}},
                        {"srcip": {"terms": {"field": "data.srcip", "missing_bucket": True}}},
                    ],
                },
                "aggs": {
                    "sample": {"top_hits": {"size": 1, "sort": [{"@timestamp": {"order": "desc"}}]}},
                    "first_seen": {"min": {"field": "@timestamp"}},
                },
            },
        },
    }).encode()

    req = urllib.request.Request(
        f"{INDEXER_URL}/{INDEX_PATTERN}/_search", data=body, method="POST"
    )
    creds = base64.b64encode(f"{INDEXER_USER}:{INDEXER_PASSWORD}".encode()).decode()
    req.add_header("Authorization", f"Basic {creds}")
    req.add_header("Content-Type", "application/json")

    with urllib.request.urlopen(req, context=CTX, timeout=15) as resp:
        return json.load(resp)


def is_noisy(src):
    groups = set(src.get("rule", {}).get("groups", []))
    return bool(groups & NOISY_GROUPS)


def format_group(src, count, first_seen):
    srcip = src.get('data', {}).get('srcip')
    own = " [IP del propio Hermes, no un atacante]" if srcip and srcip == OWN_IP else ""
    last_seen = src.get('@timestamp')
    times = (
        f"entre {to_local(first_seen)} y {to_local(last_seen)}"
        if count > 1 and first_seen != last_seen
        else f"hora: {to_local(last_seen)}"
    )
    suffix = f" x{count}" if count > 1 else ""
    return (
        f"- [nivel {src.get('rule', {}).get('level')}, regla {src.get('rule', {}).get('id')}] "
        f"{src.get('rule', {}).get('description')}{suffix} "
        f"(agente: {src.get('agent', {}).get('name')}, "
        f"ip: {srcip or '-'}{own}, "
        f"{times})"
    )


def main():
    last_ts = load_last_check()
    data = search_alerts(last_ts)
    aggs = data.get("aggregations", {})
    newest = aggs.get("newest", {}).get("value_as_string") or aggs.get("newest", {}).get("value")
    buckets = aggs.get("groups", {}).get("buckets", [])

    if not buckets or newest is None:
        print('{"wakeAgent": false}')  # nada nuevo
        return

    save_last_check(newest)

    groups = []
    for b in buckets:
        sample = b["sample"]["hits"]["hits"][0]["_source"]
        if is_noisy(sample):
            continue
        groups.append((b["doc_count"], sample, b["first_seen"]["value_as_string"]))

    if not groups:
        print('{"wakeAgent": false}')  # todo era compliance
        return

    total_alerts = sum(c for c, _, _ in groups)
    truncated = len(buckets) >= MAX_GROUPS
    note = " (tope de grupos por corrida alcanzado, puede haber más)" if truncated else ""
    print(
        f"{total_alerts} alerta(s) nueva(s) de Wazuh en {len(groups)} grupo(s) "
        f"(nivel >= {MIN_LEVEL}, sin compliance/SCA; agrupadas por regla+agente+ip origen){note}:"
    )
    for count, src, first_seen in sorted(groups, key=lambda g: -g[0]):
        print(format_group(src, count, first_seen))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
