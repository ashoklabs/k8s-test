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


## Docker

### Sourceful
```bash
docker build -f docker/sourceful/Dockerfile -t hello-sourceful .
docker run -p 5000:5000 hello-sourceful

# Run with 4 workers (good for production)
docker run -p 5000:5000 hello-sourceful gunicorn --bind 0.0.0.0:5000 --workers 4 hello:app
```

### Sourceless
```bash
docker build -f docker/sourceless/Dockerfile -t hello-sourceless .
docker run -p 5000:5000 hello-sourceless
```

---

## Kubernetes Deployment (kind + Istio + Knative)

### Prerequisites

- [kind](https://kind.sigs.k8s.io/) cluster running
- [kubectl](https://kubernetes.io/docs/tasks/tools/) configured
- [istioctl](https://istio.io/latest/docs/setup/getting-started/) available (v1.29.2)

### 1. Create a kind cluster

```bash
kind create cluster --name kind
```

### 2. Install Istio with ingress and egress gateways

```bash
istioctl install \
  --set 'components.ingressGateways[0].enabled=true' \
  --set 'components.ingressGateways[0].name=istio-ingressgateway' \
  --set 'components.egressGateways[0].enabled=true' \
  --set 'components.egressGateways[0].name=istio-egressgateway' \
  -y
```

### 3. Install Knative Serving v1.20.3

```bash
# CRDs
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.20.3/serving-crds.yaml

# Core components
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.20.3/serving-core.yaml

# net-istio networking layer
kubectl apply -f https://github.com/knative-extensions/net-istio/releases/download/knative-v1.20.3/net-istio.yaml

# Set Istio as the ingress class
kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress-class":"istio.ingress.networking.knative.dev"}}'

# Set external domain
kubectl patch configmap/config-domain \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"example.com":""}}'

# Allow local images (kind.local registry prefix skips Docker Hub digest resolution)
kubectl patch configmap config-deployment -n knative-serving --type merge \
  -p '{"data":{"registries-skipping-tag-resolving":"ko.local,dev.local,kind.local"}}'
```

### 4. Build and load the image into kind

```bash
# Build the sourceless image
docker build -f docker/sourceless/Dockerfile -t hello-sourceless:latest .

# Tag for kind.local (required to bypass Knative's Docker Hub digest check)
docker tag hello-sourceless:latest kind.local/hello-sourceless:latest

# Load both tags into the kind cluster
kind load docker-image hello-sourceless:latest --name kind
kind load docker-image kind.local/hello-sourceless:latest --name kind
```

### 5. Deploy the Knative Service

```bash
kubectl apply -f k8s/kservice.yaml
```

Verify it is ready:

```bash
kubectl get ksvc hello-sourceless
# READY column should show True
```

### 6. Access the app locally

Port-forward the Istio ingress gateway:

```bash
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
```

In a separate terminal, curl with the Knative hostname:

```bash
# Home
curl -s --noproxy localhost \
  -H "Host: hello-sourceless.default.example.com" \
  http://localhost:8080/ | python3 -m json.tool

# Health check
curl -s --noproxy localhost \
  -H "Host: hello-sourceless.default.example.com" \
  http://localhost:8080/health | python3 -m json.tool
```

> **Tip:** To avoid passing the `Host` header every time, add an entry to `/etc/hosts`:
> ```bash
> echo "127.0.0.1 hello-sourceless.default.example.com" | sudo tee -a /etc/hosts
> ```
> Then curl directly:
> ```bash
> curl -s --noproxy localhost http://hello-sourceless.default.example.com:8080/ | python3 -m json.tool
> ```

### Verify all components

```bash
kubectl get pods -n istio-system
kubectl get pods -n knative-serving
kubectl get ksvc,revision -n default
kubectl get virtualservice -n default
```

---

## TLS (HTTPS) Setup

This section adds HTTPS termination at the Istio ingress gateway using a self-signed certificate.
The existing HTTP setup continues to work — TLS is served on a separate gateway and port.

### Architecture

```
curl (HTTPS + SNI)
  └─► localhost:8443  (port-forward)
        └─► istio-ingressgateway:443
              └─► hello-tls-gateway  (Istio Gateway, SIMPLE TLS)
                    └─► hello-sourceless-tls  (VirtualService)
                          └─► hello-sourceless-00002:80  (Knative revision pod)
```

### 1. Generate a self-signed certificate

```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/tls.key \
  -out certs/tls.crt \
  -subj "/CN=hello-sourceless.default.example.com/O=local-dev" \
  -addext "subjectAltName=DNS:hello-sourceless.default.example.com,DNS:*.default.example.com"
```

> **Note:** The `certs/` directory is git-ignored. Never commit private keys.

### 2. Create the TLS secret in istio-system

The Istio ingressgateway proxy loads certificates from its own namespace (`istio-system`) via SDS.

```bash
kubectl create secret tls hello-sourceless-tls \
  --cert=certs/tls.crt \
  --key=certs/tls.key \
  -n istio-system
```

### 3. Apply the TLS manifests

```bash
kubectl apply -f k8s/tls/
```

This creates:
- `hello-tls-gateway` (Istio Gateway) — listens on port 443 with `SIMPLE` TLS mode, references the secret
- `hello-sourceless-tls` (VirtualService) — routes HTTPS traffic to the Knative revision pod

Verify the cert is loaded by Envoy:

```bash
istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system | grep hello
# Should show: kubernetes://hello-sourceless-tls  CA  ACTIVE  true ...
```

Verify the SNI listener:

```bash
istioctl proxy-config listeners deploy/istio-ingressgateway -n istio-system --port 8443
# Should show SNI: hello-sourceless.default.example.com
```

### 4. Access the app over HTTPS

Port-forward the HTTPS port:

```bash
kubectl port-forward -n istio-system svc/istio-ingressgateway 8443:443
```

In a separate terminal, use `--resolve` to send the correct TLS SNI while connecting to the port-forwarded address.
Also exclude the domain from any corporate proxy with `--noproxy`:

```bash
# Home
curl -sk \
  --noproxy "localhost,127.0.0.1,hello-sourceless.default.example.com" \
  --resolve "hello-sourceless.default.example.com:8443:127.0.0.1" \
  https://hello-sourceless.default.example.com:8443/ | python3 -m json.tool

# Health check
curl -sk \
  --noproxy "localhost,127.0.0.1,hello-sourceless.default.example.com" \
  --resolve "hello-sourceless.default.example.com:8443:127.0.0.1" \
  https://hello-sourceless.default.example.com:8443/health | python3 -m json.tool
```

> **Why `--resolve` instead of `-H "Host:"`?**
> TLS SNI is sent during the handshake (before HTTP headers). curl sets the SNI from
> the URL hostname, not from `Host:` headers. `--resolve` tells curl to connect to
> `127.0.0.1` for that hostname while preserving the hostname in the SNI extension.

> **Why `-k` (skip verification)?**
> The certificate is self-signed and not trusted by your system's CA store. To trust it
> without `-k`, run:
> ```bash
> # macOS
> sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/tls.crt
> ```

### Renewing the certificate

When the cert expires (365 days), re-generate and update the secret:

```bash
# Re-generate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/tls.key -out certs/tls.crt \
  -subj "/CN=hello-sourceless.default.example.com/O=local-dev" \
  -addext "subjectAltName=DNS:hello-sourceless.default.example.com,DNS:*.default.example.com"

# Update secret (delete + recreate)
kubectl delete secret hello-sourceless-tls -n istio-system
kubectl create secret tls hello-sourceless-tls \
  --cert=certs/tls.crt --key=certs/tls.key -n istio-system
```

---

## mTLS (Mutual TLS) Setup

Adds a second HTTPS endpoint where **both the server and the client must present a certificate**.
The existing SIMPLE TLS endpoint (`hello-sourceless.default.example.com:8443`) is completely unchanged —
Istio uses SNI to route each hostname to its own Gateway.

### Architecture

```
curl (HTTPS + SNI + client cert)
  └─► localhost:8443  (port-forward, same port as SIMPLE TLS)
        └─► istio-ingressgateway:443
              └─► Istio SNI routing
                    ├─► hello-tls-gateway   (SNI: hello-sourceless.default.example.com)   → SIMPLE TLS
                    └─► hello-mtls-gateway  (SNI: hello-sourceless-mtls.default.example.com) → MUTUAL TLS
                          └─► hello-sourceless-mtls (VirtualService)
                                └─► hello-sourceless-00002:80
```

### PKI structure

```
ca.crt  (local-dev-ca)
  ├── mtls-server.crt   (hello-sourceless-mtls.default.example.com)  — used by ingressgateway
  └── client/client.crt (hello-client)                               — used by curl / calling service
```

### 1. Generate the CA, server cert, and client cert

```bash
mkdir -p certs/client

# CA
openssl genrsa -out certs/ca.key 2048
openssl req -new -x509 -days 365 \
  -key certs/ca.key -out certs/ca.crt \
  -subj "/CN=local-dev-ca/O=local-dev"

# Server cert — signed by CA
openssl genrsa -out certs/mtls-server.key 2048
openssl req -new -key certs/mtls-server.key -out certs/mtls-server.csr \
  -subj "/CN=hello-sourceless-mtls.default.example.com/O=local-dev"
openssl x509 -req -days 365 \
  -in certs/mtls-server.csr \
  -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
  -out certs/mtls-server.crt \
  -extfile <(echo "subjectAltName=DNS:hello-sourceless-mtls.default.example.com")

# Client cert — signed by the same CA
openssl genrsa -out certs/client/client.key 2048
openssl req -new -key certs/client/client.key -out certs/client/client.csr \
  -subj "/CN=hello-client/O=local-dev"
openssl x509 -req -days 365 \
  -in certs/client/client.csr \
  -CA certs/ca.crt -CAkey certs/ca.key \
  -out certs/client/client.crt
```

> **Note:** All files under `certs/` are git-ignored. Never commit private keys.

### 2. Create the mTLS secret in istio-system

For `MUTUAL` mode, Istio needs a **generic** secret (not a `kubernetes.io/tls` type) that carries
`tls.crt`, `tls.key`, **and** `ca.crt`. Istio automatically looks for a companion secret named
`<credentialName>-cacert` for the CA bundle.

```bash
kubectl create secret generic hello-sourceless-mtls \
  --from-file=tls.crt=certs/mtls-server.crt \
  --from-file=tls.key=certs/mtls-server.key \
  --from-file=ca.crt=certs/ca.crt \
  -n istio-system
```

### 3. Apply the mTLS manifests

```bash
kubectl apply -f k8s/tls/mtls-gateway.yaml
kubectl apply -f k8s/tls/mtls-virtualservice.yaml
```

Verify both the cert chain and CA are loaded by Envoy:

```bash
istioctl proxy-config secret deploy/istio-ingressgateway -n istio-system | grep -i mtls
# kubernetes://hello-sourceless-mtls          Cert Chain  ACTIVE  true ...
# kubernetes://hello-sourceless-mtls-cacert   CA          ACTIVE  true ...
```

Verify the SNI listener for the mTLS hostname:

```bash
istioctl proxy-config listeners deploy/istio-ingressgateway -n istio-system --port 8443
# Should show two rows — one SNI for SIMPLE TLS and one for MUTUAL TLS
```

### 4. Access the app over mTLS

Port-forward the HTTPS port (skip if already running from the TLS section):

```bash
kubectl port-forward -n istio-system svc/istio-ingressgateway 8443:443
```

**Test 1 — no client cert (must be rejected):**

```bash
curl -sk \
  --noproxy "hello-sourceless-mtls.default.example.com" \
  --resolve "hello-sourceless-mtls.default.example.com:8443:127.0.0.1" \
  --cacert certs/ca.crt \
  https://hello-sourceless-mtls.default.example.com:8443/
# Expected: curl exit 56 (connection reset) — TLS handshake rejected at gateway
```

**Test 2 — with client cert (must succeed):**

```bash
curl -sk \
  --noproxy "hello-sourceless-mtls.default.example.com" \
  --resolve "hello-sourceless-mtls.default.example.com:8443:127.0.0.1" \
  --cacert certs/ca.crt \
  --cert certs/client/client.crt \
  --key  certs/client/client.key \
  https://hello-sourceless-mtls.default.example.com:8443/ | python3 -m json.tool
```

### curl flags explained

| Flag | Purpose |
|------|---------|
| `--cacert certs/ca.crt` | Trust the server cert (it was signed by our local CA, not a public one) |
| `--cert / --key` | Present the client certificate during the TLS handshake |
| `--resolve` | Send the correct SNI while connecting via the port-forwarded `127.0.0.1` address |
| `--noproxy` | Prevent the corporate proxy from intercepting the local connection |

### Renewing mTLS certificates

```bash
# Re-generate server cert
openssl genrsa -out certs/mtls-server.key 2048
openssl req -new -key certs/mtls-server.key -out certs/mtls-server.csr \
  -subj "/CN=hello-sourceless-mtls.default.example.com/O=local-dev"
openssl x509 -req -days 365 \
  -in certs/mtls-server.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
  -out certs/mtls-server.crt \
  -extfile <(echo "subjectAltName=DNS:hello-sourceless-mtls.default.example.com")

# Update secret
kubectl delete secret hello-sourceless-mtls -n istio-system
kubectl create secret generic hello-sourceless-mtls \
  --from-file=tls.crt=certs/mtls-server.crt \
  --from-file=tls.key=certs/mtls-server.key \
  --from-file=ca.crt=certs/ca.crt \
  -n istio-system

---

## GitOps (ArgoCD + SOPS)

The entire cluster — infrastructure components (Istio, Knative) and application workloads — is managed
by ArgoCD using a GitOps model. Secrets (TLS/mTLS certificates) are encrypted in-git with
[SOPS](https://github.com/getsops/sops) + [AGE](https://age-encryption.org/) and decrypted at sync
time by the [ksops](https://github.com/viaduct-ai/kustomize-sops) Kustomize plugin running as an
ArgoCD Config Management Plugin (CMP) sidecar.

### Repository layout

```
K8s-test/
├── .sops.yaml                              ← AGE encryption rules (public key only)
│
├── argocd/
│   ├── bootstrap/
│   │   ├── bootstrap.sh                    ← One-time cluster bootstrap script
│   │   ├── argocd-namespace.yaml
│   │   ├── argocd-values.yaml              ← ArgoCD Helm values + ksops CMP sidecar config
│   │   └── sops-age-secret.yaml.template   ← Template (do NOT fill in and commit)
│   ├── projects/
│   │   ├── infrastructure.yaml             ← AppProject for Istio / Knative
│   │   └── applications.yaml              ← AppProject for workloads
│   └── apps/                              ← App-of-Apps watched by root-app
│       ├── root-app.yaml                  ← Bootstrapped once; watches this folder
│       ├── istio-base.yaml                ← wave 1 — Istio CRDs
│       ├── istiod.yaml                    ← wave 2 — Istio control plane
│       ├── istio-ingressgateway.yaml      ← wave 3 — Ingress gateway
│       ├── knative-serving-crds.yaml      ← wave 4 — Knative CRDs
│       ├── knative-serving-core.yaml      ← wave 5 — Knative core
│       ├── knative-net-istio.yaml         ← wave 6 — net-istio networking layer
│       └── hello-sourceless.yaml          ← wave 10 — app (uses ksops plugin)
│
├── infrastructure/
│   ├── istio/
│   │   ├── base/                          ← istio-system namespace
│   │   ├── istiod/values.yaml             ← Helm values for istiod
│   │   └── ingressgateway/values.yaml     ← Helm values for ingressgateway
│   └── knative/
│       ├── serving-crds/kustomization.yaml
│       ├── serving-core/kustomization.yaml
│       └── net-istio/kustomization.yaml
│
├── apps/hello-sourceless/
│   ├── kustomization.yaml
│   ├── ksvc.yaml                          ← Knative Service
│   └── tls/
│       ├── kustomization.yaml
│       ├── gateway.yaml                   ← Istio Gateway (SIMPLE TLS)
│       ├── virtualservice.yaml
│       ├── mtls-gateway.yaml              ← Istio Gateway (MUTUAL TLS)
│       ├── mtls-virtualservice.yaml
│       ├── destinationrule-upstream.yaml  ← East-West mTLS (ingressgateway → pod)
│       ├── destinationrule-external.yaml  ← Egress mTLS (pod → external API)
│       └── secrets/
│           ├── kustomization.yaml         ← Loads ksops-generator.yaml
│           ├── ksops-generator.yaml       ← Lists *.enc.yaml files for ksops
│           ├── hello-sourceless-tls.enc.yaml   ← SOPS-encrypted TLS secret
│           ├── hello-sourceless-mtls.enc.yaml  ← SOPS-encrypted mTLS secret
│           └── egress-client-creds.enc.yaml    ← SOPS-encrypted egress client secret
│
└── scripts/
    ├── generate-certs.sh                  ← (Re-)generate all certificates
    └── encrypt-secrets.sh                 ← (Re-)encrypt certs → *.enc.yaml
```

### How sync waves work

| Wave | Application | Depends on |
|------|-------------|-----------|
| 1 | `istio-base` | nothing — installs Istio CRDs first |
| 2 | `istiod` | istio-base CRDs |
| 3 | `istio-ingressgateway` | istiod running |
| 4 | `knative-serving-crds` | Istio ready |
| 5 | `knative-serving-core` | Knative CRDs |
| 6 | `knative-net-istio` | Knative core + Istio |
| 10 | `hello-sourceless` | all infrastructure |

### Secret management (SOPS + AGE)

Certificates are **never stored in plaintext** in git. Instead:

1. Raw cert files live in `certs/` (git-ignored)
2. `scripts/encrypt-secrets.sh` builds Kubernetes Secret YAMLs and encrypts them with SOPS+AGE
3. The resulting `*.enc.yaml` files are committed to `apps/hello-sourceless/tls/secrets/`
4. At ArgoCD sync time the `ksops` CMP sidecar decrypts them using the AGE private key stored
   in a Kubernetes secret (`sops-age`) in the `argocd` namespace

```
certs/ (local, gitignored)
  └─► scripts/encrypt-secrets.sh
        └─► apps/.../secrets/*.enc.yaml  (committed, SOPS-encrypted)
              └─► ArgoCD ksops CMP (decrypts at sync)
                    └─► Kubernetes Secret in istio-system
```

AGE key pair:

| Item | Where |
|------|-------|
| Public key | `.sops.yaml` (safe to commit) |
| Private key | `age.agekey` locally (gitignored) + `SOPS_AGE_PRIVATE_KEY` GitHub secret |
| In-cluster | `kubectl create secret generic sops-age --from-file=keys.agekey=age.agekey -n argocd` |

### First-time bootstrap

> Prerequisites: `kubectl`, `helm`, `age`, `sops` installed; kubeconfig pointing at your cluster.

**1. Set your repository URL**

Replace `https://github.com/YOUR_ORG/K8s-test.git` in the following files:
- `argocd/apps/root-app.yaml`
- `argocd/apps/istiod.yaml`
- `argocd/apps/istio-ingressgateway.yaml`
- `argocd/apps/hello-sourceless.yaml`
- `argocd/projects/infrastructure.yaml`
- `argocd/projects/applications.yaml`

**2. Store the AGE private key as a GitHub secret**

```bash
# Print the private key to copy into GitHub → Settings → Secrets → SOPS_AGE_PRIVATE_KEY
cat age.agekey
```

**3. Run the bootstrap script**

```bash
./argocd/bootstrap/bootstrap.sh https://github.com/YOUR_ORG/K8s-test.git
```

The script:
1. Creates the `argocd` namespace
2. Creates the `sops-age` secret from your local `age.agekey`
3. Installs ArgoCD via Helm with the ksops CMP sidecar
4. Applies AppProjects
5. Applies the root App-of-Apps — ArgoCD takes over from here

**4. Access the ArgoCD UI**

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
# Username: admin
# Password:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Rotating or renewing certificates

```bash
# 1. Regenerate certificates (or update just the ones that expired)
./scripts/generate-certs.sh

# 2. Re-encrypt and commit
./scripts/encrypt-secrets.sh
git add apps/hello-sourceless/tls/secrets/*.enc.yaml
git commit -m "chore: rotate TLS certificates"
git push

# ArgoCD detects the change and re-syncs automatically, updating the secrets in-cluster.
```

### GitHub Actions — automatic re-encryption

The workflow `.github/workflows/encrypt-secrets.yml` triggers whenever files under `certs/` are
pushed and re-encrypts them automatically. In practice you will run `encrypt-secrets.sh` locally
before committing, but the workflow acts as a safety net.

> **Required GitHub secret:** `SOPS_AGE_PRIVATE_KEY` — the full contents of your `age.agekey` file.
```