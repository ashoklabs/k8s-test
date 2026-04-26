# Hello API

A minimal Flask API that returns the hostname and a trace ID per request.

## Setup

```bash
python3 -m venv venv
source venv/bin/activate
pip install flask
```

## Run

```bash
flask --app hello run
```

> **Note:** On macOS, port 5000 may be used by AirPlay. Use `--port 5001` if needed.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Hello message + hostname + trace ID |
| GET | `/health` | Health status + hostname + trace ID |

## curl Examples

> **Note:** Use `--noproxy localhost` if you're behind a corporate proxy.

```bash
# Home
curl -s --noproxy localhost http://localhost:5000/ | python3 -m json.tool

# Health check
curl -s --noproxy localhost http://localhost:5000/health | python3 -m json.tool

# Pass a custom trace ID
curl -s --noproxy localhost -H "X-Trace-Id: my-trace-123" http://localhost:5000/ | python3 -m json.tool

# See trace ID in response headers
curl -si --noproxy localhost http://localhost:5000/ | grep X-Trace-Id
```

## Example Response

```json
{
    "hostname": "xx-xxx-3534",
    "message": "Hello, World!",
    "trace_id": "d5a055af-4b63-4734-8b2b-bccb6fb8580d"
}
```


# Sourceful
docker build -f docker/sourceful/Dockerfile -t hello-sourceful .
docker run -p 5000:5000 hello-sourceful

# Sourceless
docker build -f docker/sourceless/Dockerfile -t hello-sourceless .
docker run -p 5000:5000 hello-sourceless


# Run with 4 workers (good for production)
docker run -p 5000:5000 hello-sourceful gunicorn --bind 0.0.0.0:5000 --workers 4 hello:app