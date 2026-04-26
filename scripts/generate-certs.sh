#!/usr/bin/env bash
# generate-certs.sh — regenerate all TLS/mTLS certificates under certs/.
# After running this, re-run scripts/encrypt-secrets.sh to re-encrypt.
#
# Usage: ./scripts/generate-certs.sh [domain-suffix]
# Default domain suffix: default.example.com

set -euo pipefail

DOMAIN="${1:-default.example.com}"
CERTS="certs"
DAYS=825

mkdir -p "${CERTS}/client"

echo "==> [1/4] CA certificate"
openssl genrsa -out "${CERTS}/ca.key" 4096
openssl req -new -x509 -days "${DAYS}" -key "${CERTS}/ca.key" \
  -subj "/CN=local-dev-ca/O=local-dev" \
  -out "${CERTS}/ca.crt"

echo "==> [2/4] Simple TLS server cert (hello-sourceless.${DOMAIN})"
openssl genrsa -out "${CERTS}/tls.key" 2048
openssl req -new -key "${CERTS}/tls.key" \
  -subj "/CN=hello-sourceless.${DOMAIN}" \
  -out /tmp/tls.csr
openssl x509 -req -days "${DAYS}" \
  -in /tmp/tls.csr \
  -CA "${CERTS}/ca.crt" -CAkey "${CERTS}/ca.key" -CAcreateserial \
  -extfile <(printf "subjectAltName=DNS:hello-sourceless.${DOMAIN},DNS:*.${DOMAIN}") \
  -out "${CERTS}/tls.crt"

echo "==> [3/4] mTLS server cert (hello-sourceless-mtls.${DOMAIN})"
openssl genrsa -out "${CERTS}/mtls-server.key" 2048
openssl req -new -key "${CERTS}/mtls-server.key" \
  -subj "/CN=hello-sourceless-mtls.${DOMAIN}" \
  -out /tmp/mtls-server.csr
openssl x509 -req -days "${DAYS}" \
  -in /tmp/mtls-server.csr \
  -CA "${CERTS}/ca.crt" -CAkey "${CERTS}/ca.key" -CAcreateserial \
  -extfile <(printf "subjectAltName=DNS:hello-sourceless-mtls.${DOMAIN},DNS:*.${DOMAIN}") \
  -out "${CERTS}/mtls-server.crt"

echo "==> [4/4] mTLS client cert (hello-client)"
openssl genrsa -out "${CERTS}/client/client.key" 2048
openssl req -new -key "${CERTS}/client/client.key" \
  -subj "/CN=hello-client/O=local-dev" \
  -out /tmp/client.csr
openssl x509 -req -days "${DAYS}" \
  -in /tmp/client.csr \
  -CA "${CERTS}/ca.crt" -CAkey "${CERTS}/ca.key" -CAcreateserial \
  -out "${CERTS}/client/client.crt"

echo ""
echo "Certificates generated in ${CERTS}/"
echo "Next: ./scripts/encrypt-secrets.sh"
