"""Servicio web de la evaluación final DGITI.

Endpoints:
  GET  /             página que muestra qué instancia y zona atendió la solicitud
  GET  /health       endpoint de validación del balanceador (no depende de la BD)
  GET  /status       estado de la conexión con la BD primaria y con la réplica
  GET  /api/info     datos de la instancia (id, zona, versión)
  POST /api/visits   escribe una visita en la BD primaria
  GET  /api/visits   lee el total de visitas desde la réplica
  GET  /api/stress   consume CPU durante ?ms= milisegundos (prueba de carga)
"""
import os
import socket
import time

import pymysql
from flask import Flask, jsonify, request

app = Flask(__name__)

INSTANCE_ID = os.environ.get("INSTANCE_ID", socket.gethostname())
AZ = os.environ.get("AZ", "local")
APP_VERSION = os.environ.get("APP_VERSION", "dev")
MAX_STRESS_MS = 500


def db_config(role):
    host_var = "DB_HOST" if role == "primary" else "DB_REPLICA_HOST"
    return {
        "host": os.environ.get(host_var, ""),
        "port": int(os.environ.get("DB_PORT", "3306")),
        "user": os.environ.get("DB_USER", ""),
        "password": os.environ.get("DB_PASSWORD", ""),
        "database": os.environ.get("DB_NAME", "appdb"),
        "connect_timeout": 3,
    }


def get_connection(role):
    cfg = db_config(role)
    if not cfg["host"]:
        raise RuntimeError("host de base de datos no configurado (%s)" % role)
    return pymysql.connect(autocommit=True, **cfg)


def check_db(role):
    try:
        conn = get_connection(role)
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        finally:
            conn.close()
        return {"ok": True}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def ensure_schema(conn):
    with conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS visits ("
            " id INT AUTO_INCREMENT PRIMARY KEY,"
            " instance_id VARCHAR(64) NOT NULL,"
            " created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)"
        )


def instance_data():
    return {"instance_id": INSTANCE_ID, "az": AZ, "version": APP_VERSION}


@app.get("/")
def index():
    return (
        "<html><head><title>DGITI EF</title></head>"
        "<body style='font-family:sans-serif;text-align:center;margin-top:15vh'>"
        "<h1>Servicio DGITI - Evaluaci&oacute;n final</h1>"
        "<h2>Atendido por la instancia <b>%s</b></h2>"
        "<h2>Zona de disponibilidad: <b>%s</b></h2>"
        "<p>Versi&oacute;n %s &middot; recarga la p&aacute;gina para ver el balanceo</p>"
        "</body></html>" % (INSTANCE_ID, AZ, APP_VERSION)
    )


@app.get("/health")
def health():
    return jsonify(status="ok", **instance_data())


@app.get("/status")
def status():
    primary = check_db("primary")
    replica = check_db("replica")
    ok = primary["ok"] and replica["ok"]
    body = dict(instance_data(), ok=ok, db={"primary": primary, "replica": replica})
    return jsonify(body), (200 if ok else 503)


@app.get("/api/info")
def info():
    return jsonify(hostname=socket.gethostname(), time=time.time(), **instance_data())


@app.post("/api/visits")
def add_visit():
    try:
        conn = get_connection("primary")
        try:
            ensure_schema(conn)
            with conn.cursor() as cur:
                cur.execute("INSERT INTO visits (instance_id) VALUES (%s)", (INSTANCE_ID,))
        finally:
            conn.close()
    except Exception as exc:
        return jsonify(ok=False, error=str(exc)), 503
    return jsonify(ok=True, written_to="primary", **instance_data()), 201


@app.get("/api/visits")
def count_visits():
    try:
        conn = get_connection("primary")
        try:
            ensure_schema(conn)
        finally:
            conn.close()
    except Exception as exc:
        return jsonify(ok=False, error=str(exc)), 503

    for role in ("replica", "primary"):
        try:
            conn = get_connection(role)
            try:
                with conn.cursor() as cur:
                    cur.execute("SELECT COUNT(*) FROM visits")
                    total = cur.fetchone()[0]
            finally:
                conn.close()
            return jsonify(ok=True, total=total, read_from=role, **instance_data())
        except Exception:
            continue
    return jsonify(ok=False, error="no se pudo leer la base de datos"), 503


@app.get("/api/stress")
def stress():
    try:
        ms = int(request.args.get("ms", "50"))
    except ValueError:
        return jsonify(ok=False, error="ms debe ser un entero"), 400
    ms = max(0, min(ms, MAX_STRESS_MS))
    end = time.perf_counter() + ms / 1000.0
    n = 0
    while time.perf_counter() < end:
        n += 1
    return jsonify(ok=True, ms=ms, iterations=n, **instance_data())


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
