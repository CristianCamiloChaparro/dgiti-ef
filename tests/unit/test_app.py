"""Pruebas unitarias: la base de datos se reemplaza por objetos simulados."""
from unittest.mock import MagicMock, patch

import pytest

import app as service


@pytest.fixture
def client():
    service.app.config["TESTING"] = True
    with service.app.test_client() as c:
        yield c


def fake_connection(fetch_result=(1,)):
    conn = MagicMock()
    cursor = conn.cursor.return_value.__enter__.return_value
    cursor.fetchone.return_value = fetch_result
    return conn


def test_health_responde_200(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.get_json()["status"] == "ok"


def test_health_no_depende_de_la_bd(client):
    with patch.object(service, "get_connection", side_effect=RuntimeError("bd caida")):
        assert client.get("/health").status_code == 200


def test_index_muestra_instancia_y_zona(client):
    html = client.get("/").get_data(as_text=True)
    assert service.INSTANCE_ID in html
    assert service.AZ in html


def test_info_tiene_los_campos(client):
    data = client.get("/api/info").get_json()
    assert {"instance_id", "az", "version", "hostname"} <= set(data)


def test_status_ok_con_primaria_y_replica(client):
    with patch.object(service, "get_connection", side_effect=lambda role: fake_connection()):
        r = client.get("/status")
    assert r.status_code == 200
    data = r.get_json()
    assert data["ok"] is True
    assert data["db"]["primary"]["ok"] and data["db"]["replica"]["ok"]


def test_status_503_si_falla_la_replica(client):
    def conn(role):
        if role == "replica":
            raise RuntimeError("replica caida")
        return fake_connection()

    with patch.object(service, "get_connection", side_effect=conn):
        r = client.get("/status")
    assert r.status_code == 503
    assert r.get_json()["db"]["replica"]["ok"] is False


def test_status_503_si_falla_la_primaria(client):
    def conn(role):
        if role == "primary":
            raise RuntimeError("primaria caida")
        return fake_connection()

    with patch.object(service, "get_connection", side_effect=conn):
        r = client.get("/status")
    assert r.status_code == 503
    assert r.get_json()["db"]["primary"]["ok"] is False


def test_post_visits_escribe_en_la_primaria(client):
    roles = []

    def conn(role):
        roles.append(role)
        return fake_connection()

    with patch.object(service, "get_connection", side_effect=conn):
        r = client.post("/api/visits")
    assert r.status_code == 201
    assert r.get_json()["written_to"] == "primary"
    assert roles == ["primary"]


def test_post_visits_503_sin_bd(client):
    with patch.object(service, "get_connection", side_effect=RuntimeError("sin bd")):
        assert client.post("/api/visits").status_code == 503


def test_get_visits_lee_de_la_replica(client):
    with patch.object(service, "get_connection", side_effect=lambda role: fake_connection((7,))):
        data = client.get("/api/visits").get_json()
    assert data["read_from"] == "replica"
    assert data["total"] == 7


def test_get_visits_usa_la_primaria_si_falla_la_replica(client):
    def conn(role):
        if role == "replica":
            raise RuntimeError("replica caida")
        return fake_connection((3,))

    with patch.object(service, "get_connection", side_effect=conn):
        data = client.get("/api/visits").get_json()
    assert data["read_from"] == "primary"
    assert data["total"] == 3


def test_stress_por_defecto(client):
    data = client.get("/api/stress").get_json()
    assert data["ok"] is True
    assert data["ms"] == 50


def test_stress_limita_el_maximo(client):
    data = client.get("/api/stress?ms=99999").get_json()
    assert data["ms"] == service.MAX_STRESS_MS


def test_stress_rechaza_valores_invalidos(client):
    assert client.get("/api/stress?ms=abc").status_code == 400


def test_get_connection_exige_host(monkeypatch):
    monkeypatch.delenv("DB_REPLICA_HOST", raising=False)
    with pytest.raises(RuntimeError):
        service.get_connection("replica")
