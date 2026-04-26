# ── Sourceful Image ───────────────────────────────────────────────────────────
# Includes full Python source code. Good for development and debugging.
# Build:  docker build -f docker/sourceful/Dockerfile -t hello-sourceful .
# Run:    docker run -p 5000:5000 hello-sourceful
# ─────────────────────────────────────────────────────────────────────────────

FROM python:3.11-slim

# Security: run as a non-root user
RUN useradd --no-create-home --shell /bin/false appuser

WORKDIR /app

# Install dependencies as a separate layer (improves build caching)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source
COPY hello.py .

USER appuser

EXPOSE 5000

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "hello:app"]
