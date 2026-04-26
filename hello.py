from flask import Flask, jsonify, request, g
import socket
import uuid
import logging
import os

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.propagators.b3 import B3MultiFormat
from opentelemetry.propagate import set_global_textmap

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)

# ── OpenTelemetry setup ───────────────────────────────────────────────────────
# OTLP HTTP endpoint — defaults to Jaeger in-cluster; override via env var
OTLP_ENDPOINT = os.getenv(
    "OTLP_ENDPOINT",
    "http://jaeger-collector.istio-system.svc.cluster.local:4318",
)

provider = TracerProvider()
exporter = OTLPSpanExporter(endpoint=f"{OTLP_ENDPOINT}/v1/traces")
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

# B3 multi-format propagation — reads x-b3-traceid/spanid injected by Istio sidecars
# so Flask spans become children of the Envoy-generated trace
set_global_textmap(B3MultiFormat())

tracer = trace.get_tracer("hello-sourceless")

# ── Flask app ─────────────────────────────────────────────────────────────────
app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)   # auto-creates spans; extracts B3 context

hostname = socket.gethostname()


@app.before_request
def assign_trace_id():
    # Use incoming X-Trace-Id header if present, otherwise generate one
    g.trace_id = request.headers.get("X-Trace-Id", str(uuid.uuid4()))


@app.after_request
def finalize_response(response):
    response.headers["X-Trace-Id"] = g.trace_id
    # Tag the current OTel span (created by FlaskInstrumentor) with our custom trace ID
    span = trace.get_current_span()
    if span.is_recording():
        span.set_attribute("app.trace_id", g.trace_id)
    ctx = span.get_span_context()
    otel_trace_id = format(ctx.trace_id, "032x") if ctx.is_valid else "none"
    logger.info(
        "method=%s path=%s status=%d x_trace_id=%s otel_trace_id=%s",
        request.method, request.path, response.status_code,
        g.trace_id, otel_trace_id,
    )
    return response


@app.route("/")
def home():
    return jsonify(message="Hello, World!", hostname=hostname, trace_id=g.trace_id)


@app.route("/health")
def health():
    return jsonify(status="ok", hostname=hostname, trace_id=g.trace_id)


if __name__ == "__main__":
    print(f"Running on hostname: {hostname}")
    app.run(host="0.0.0.0", port=5000)

