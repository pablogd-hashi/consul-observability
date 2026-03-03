"""
db-api: simulated database tier, called by backend-api.
Demonstrates 3-hop service mesh tracing: example-app → backend-api → db-api.
"""
import os
import time
import random
import logging
from flask import Flask, jsonify, request

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor

# ── OTEL setup ────────────────────────────────────────────────────────────────
resource = Resource.create({
    "service.name": os.environ.get("OTEL_SERVICE_NAME", "db-api"),
    "service.version": "1.0.0",
    "service.tier": "data",
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

# Simulated data store
RECORDS = [
    {"id": 1, "name": "widget",     "stock": 142, "warehouse": "A"},
    {"id": 2, "name": "gadget",     "stock": 87,  "warehouse": "B"},
    {"id": 3, "name": "doohickey",  "stock": 34,  "warehouse": "A"},
    {"id": 4, "name": "thingamajig","stock": 210, "warehouse": "C"},
    {"id": 5, "name": "whatsit",    "stock": 6,   "warehouse": "B"},
]

SCHEMA = {
    "table": "products",
    "columns": ["id", "name", "stock", "warehouse"],
    "indexes": ["id", "warehouse"],
    "row_count": len(RECORDS),
}


@app.route("/health")
def health():
    return jsonify({"status": "healthy", "service": "db-api"}), 200


@app.route("/query")
def query():
    """Simulates a DB query with realistic latency distribution."""
    with tracer.start_as_current_span("db.query") as span:
        table = request.args.get("table", "products")
        limit = int(request.args.get("limit", len(RECORDS)))

        span.set_attribute("db.system", "postgresql")
        span.set_attribute("db.name", "products_db")
        span.set_attribute("db.statement", f"SELECT * FROM {table} LIMIT {limit}")
        span.set_attribute("db.table", table)

        # Simulate realistic DB latency:
        # 80% fast (10-30ms), 15% medium (30-80ms), 5% slow (80-300ms)
        roll = random.random()
        if roll < 0.80:
            latency = random.uniform(0.010, 0.030)
        elif roll < 0.95:
            latency = random.uniform(0.030, 0.080)
        else:
            latency = random.uniform(0.080, 0.300)   # slow query
            span.set_attribute("db.slow_query", True)

        with tracer.start_as_current_span("db.execute"):
            time.sleep(latency)

        results = RECORDS[:limit]
        span.set_attribute("db.rows_returned", len(results))
        span.set_attribute("db.latency_ms", round(latency * 1000, 2))

        return jsonify({
            "table": table,
            "rows": results,
            "count": len(results),
            "query_time_ms": round(latency * 1000, 2),
        })


@app.route("/schema")
def schema():
    """Returns table schema metadata."""
    with tracer.start_as_current_span("db.schema-lookup"):
        time.sleep(random.uniform(0.002, 0.008))
        return jsonify(SCHEMA)


if __name__ == "__main__":
    logger.info("Starting db-api on port 8082")
    app.run(host="0.0.0.0", port=8082)
