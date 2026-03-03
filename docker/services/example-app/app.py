"""
example-app: frontend service that calls backend-api downstream.
Demonstrates service-to-service tracing through the mesh.
"""
import os
import time
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

# ── OTEL setup ───────────────────────────────────────────────────────────────
resource = Resource.create({
    "service.name": os.environ.get("OTEL_SERVICE_NAME", "example-app"),
    "service.version": os.environ.get("OTEL_RESOURCE_ATTRIBUTES", "service.version=1.0.0")
        .split("service.version=")[-1],
})

otlp_endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
exporter = OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)
provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)

# Instrument outbound HTTP calls so trace context propagates to backend-api
RequestsInstrumentor().instrument()

# ── Flask app ─────────────────────────────────────────────────────────────────
app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

BACKEND_URL = os.environ.get("BACKEND_URL", "http://backend-api:8081")


@app.route("/")
def index():
    with tracer.start_as_current_span("handle-index") as span:
        span.set_attribute("http.route", "/")
        time.sleep(0.005)
        return jsonify({
            "service": "example-app",
            "status": "ok",
            "message": "Hello from Consul service mesh!"
        })


@app.route("/health")
def health():
    return jsonify({"status": "healthy"}), 200


@app.route("/work")
def work():
    """Calls backend-api /data then /compute — creates cross-service spans."""
    with tracer.start_as_current_span("handle-work") as span:
        span.set_attribute("http.route", "/work")

        # Call downstream service — OTel will propagate trace context
        with tracer.start_as_current_span("call-backend-data"):
            resp = requests.get(f"{BACKEND_URL}/data", timeout=5)
            items = resp.json().get("items", [])
            span.set_attribute("backend.items_count", len(items))

        with tracer.start_as_current_span("call-backend-compute"):
            resp = requests.get(f"{BACKEND_URL}/compute", timeout=5)
            result = resp.json().get("result", 0)
            span.set_attribute("backend.compute_result", result)

        return jsonify({"items": items, "result": result, "status": "ok"})


@app.route("/data")
def data():
    """Proxy to backend-api /data."""
    with tracer.start_as_current_span("handle-data"):
        resp = requests.get(f"{BACKEND_URL}/data", timeout=5)
        return jsonify(resp.json())


if __name__ == "__main__":
    logger.info("Starting example-app on port 8080")
    app.run(host="0.0.0.0", port=8080)
