"""
backend-api: middle tier. Fetches data from db-api and does compute work.
Creates 3-hop service mesh tracing: example-app → backend-api → db-api.
"""
import os
import time
import random
import logging
import requests
from flask import Flask, jsonify

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor

# ── OTEL setup ────────────────────────────────────────────────────────────────
resource = Resource.create({
    "service.name": os.environ.get("OTEL_SERVICE_NAME", "backend-api"),
    "service.version": "1.0.0",
    "service.tier": "api",
})

otlp_endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
exporter = OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)

RequestsInstrumentor().instrument()

# ── Flask app ─────────────────────────────────────────────────────────────────
app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

DB_URL = os.environ.get("BACKEND_DB_URL", "http://db-api:8082")


@app.route("/health")
def health():
    return jsonify({"status": "healthy", "service": "backend-api"}), 200


@app.route("/data")
def data():
    """Fetches product data from db-api, then enriches it."""
    with tracer.start_as_current_span("backend.fetch-data") as span:
        # Call downstream db-api — OTel propagates trace context automatically
        with tracer.start_as_current_span("backend.call-db"):
            resp = requests.get(f"{DB_URL}/query", timeout=5)
            db_data = resp.json()

        rows = db_data.get("rows", [])
        span.set_attribute("db.rows_returned", len(rows))
        span.set_attribute("db.query_time_ms", db_data.get("query_time_ms", 0))

        # Light enrichment
        with tracer.start_as_current_span("backend.enrich"):
            enriched = [
                {**row, "price": round(random.uniform(1.99, 49.99), 2)}
                for row in rows
            ]

        return jsonify({"items": enriched, "count": len(enriched)})


@app.route("/compute")
def compute():
    """CPU-bound computation, occasionally slow (10% of requests)."""
    with tracer.start_as_current_span("backend.compute") as span:
        with tracer.start_as_current_span("backend.heavy-work"):
            if random.random() < 0.10:
                time.sleep(0.200)   # simulate slow path
            result = sum(i ** 2 for i in range(2000))
        span.set_attribute("compute.result", result)
        return jsonify({"result": result, "status": "ok"})


@app.route("/schema")
def schema():
    """Proxies db-api schema info."""
    with tracer.start_as_current_span("backend.get-schema"):
        resp = requests.get(f"{DB_URL}/schema", timeout=5)
        return jsonify(resp.json())


if __name__ == "__main__":
    logger.info("Starting backend-api on port 8081")
    app.run(host="0.0.0.0", port=8081)
