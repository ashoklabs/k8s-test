#!/usr/bin/env bash
# encrypt-secrets.sh — (re-)encrypt certificate secrets for git storage.
# Run this whenever you rotate or regenerate certificates.
#
# Usage:
#   export SOPS_AGE_KEY_FILE=age.agekey   # or point to your key file
#   ./scripts/encrypt-secrets.sh
#
# Requirements: age, sops, openssl/cfssl (for cert generation)

set -euo pipefail

AGE_PUBKEY="age1ntkh6h060tngaw8k6jdvvj9hmaydf7zar4hzvpncfur78yqhd9psukzdv5"
CERTS="certs"
DEST="apps/hello-sourceless/tls/secrets"

echo "==> Building plaintext secret YAMLs from ${CERTS}/"

TLS_CRT=$(base64 < "${CERTS}/tls.crt" | tr -d '\n')
TLS_KEY=$(base64 < "${CERTS}/tls.key" | tr -d '\n')
MTLS_CRT=$(base64 < "${CERTS}/mtls-server.crt" | tr -d '\n')
MTLS_KEY=$(base64 < "${CERTS}/mtls-server.key" | tr -d '\n')
CA_CRT=$(base64 < "${CERTS}/ca.crt" | tr -d '\n')
CLIENT_CRT=$(base64 < "${CERTS}/client/client.crt" | tr -d '\n')
CLIENT_KEY=$(base64 < "${CERTS}/client/client.key" | tr -d '\n')

# ── 1. Simple TLS ──────────────────────────────────────────────────────────
cat > /tmp/hello-sourceless-tls.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: hello-sourceless-tls
  namespace: istio-system
type: kubernetes.io/tls
data:
  tls.crt: ${TLS_CRT}
  tls.key: ${TLS_KEY}
EOF

# ── 2. Mutual TLS ──────────────────────────────────────────────────────────
cat > /tmp/hello-sourceless-mtls.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: hello-sourceless-mtls
  namespace: istio-system
type: Opaque
data:
  tls.crt: ${MTLS_CRT}
  tls.key: ${MTLS_KEY}
  ca.crt: ${CA_CRT}
EOF

# ── 3. Egress client creds ─────────────────────────────────────────────────
cat > /tmp/egress-client-creds.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: egress-client-creds
  namespace: istio-system
type: Opaque
data:
  tls.crt: ${CLIENT_CRT}
  tls.key: ${CLIENT_KEY}
  ca.crt: ${CA_CRT}
EOF

echo "==> Encrypting with SOPS+AGE"

for pair in \
  "/tmp/hello-sourceless-tls.yaml:${DEST}/hello-sourceless-tls.enc.yaml" \
  "/tmp/hello-sourceless-mtls.yaml:${DEST}/hello-sourceless-mtls.enc.yaml" \
  "/tmp/egress-client-creds.yaml:${DEST}/egress-client-creds.enc.yaml"; do
  src="${pair%%:*}"
  dst="${pair##*:}"
  cp "${src}" "${dst}"
  sops --encrypt --age "${AGE_PUBKEY}" --in-place "${dst}"
  echo "  ✓ ${dst}"
done

echo ""
echo "Done. Commit the *.enc.yaml files in ${DEST}/"
