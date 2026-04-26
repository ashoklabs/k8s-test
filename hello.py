from flask import Flask, jsonify, request, g
import socket
import uuid

app = Flask(__name__)
hostname = socket.gethostname()

@app.before_request
def assign_trace_id():
    # Use incoming X-Trace-Id header if present, otherwise generate one
    g.trace_id = request.headers.get("X-Trace-Id", str(uuid.uuid4()))

@app.after_request
def add_trace_header(response):
    response.headers["X-Trace-Id"] = g.trace_id
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

