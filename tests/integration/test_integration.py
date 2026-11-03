"""Pruebas de integración contra el balanceador real.

Se ejecutan solo si existe la variable BASE_URL, por ejemplo:
    BASE_URL=http://dgiti-ef-alb-123.us-east-1.elb.amazonaws.com pytest tests/integration
"""
import json
import os
import urllib.request

import pytest

BASE_URL = os.environ.get("BASE_URL", "").rstrip("/")

pytestmark = pytest.mark.skipif(not BASE_URL, reason="BASE_URL no definida")


def call(path, method="GET"):
    data = b"" if method == "POST" else None
    req = urllib.request.Request(BASE_URL + path, method=method, data=data)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status, json.loads(resp.read().decode())


def test_health():
    status, body = call("/health")
    assert status == 200
    assert body["status"] == "ok"


def test_status_primaria_y_replica():
    status, body = call("/status")
    assert status == 200
    assert body["db"]["primary"]["ok"] is True
    assert body["db"]["replica"]["ok"] is True


def test_visitas_escribe_y_lee():
    status, body = call("/api/visits", method="POST")
    assert status == 201
    assert body["written_to"] == "primary"
    status, body = call("/api/visits")
    assert status == 200
    assert body["total"] >= 1


def test_balanceador_reparte_entre_instancias():
    instancias = {call("/api/info")[1]["instance_id"] for _ in range(20)}
    assert len(instancias) >= 2, "el balanceador solo devolvió %s" % instancias
