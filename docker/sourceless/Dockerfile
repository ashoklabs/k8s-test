# ── Sourceless Image (multi-stage + distroless) ───────────────────────────────
# Final image has NO shell, NO package manager, and NO .py source files.
# Only compiled bytecode (.pyc) + dependencies. Minimal attack surface.
# Build:  docker build -f docker/sourceless/Dockerfile -t hello-sourceless .
# Run:    docker run -p 5000:5000 hello-sourceless
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: builder ─────────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /app

# Install dependencies into an isolated directory
COPY requirements.txt .
RUN pip install --no-cache-dir --target=/app/packages -r requirements.txt

# Copy source, compile to bytecode (-b = .pyc next to .py), then remove source
COPY hello.py .
RUN python3 -m compileall -b hello.py && rm hello.py

# ── Stage 2: distroless runtime ──────────────────────────────────────────────
# No shell, no apt, no OS tools — only Python + your app
FROM gcr.io/distroless/python3-debian12

WORKDIR /app

COPY --from=builder /app/packages ./packages
COPY --from=builder /app/hello.pyc .

# Make installed packages importable
ENV PYTHONPATH=/app/packages

EXPOSE 5000

# gunicorn can import hello.pyc by module name since Python resolves .pyc on PYTHONPATH
ENTRYPOINT ["python3", "-m", "gunicorn", "--bind", "0.0.0.0:5000", "hello:app"]
