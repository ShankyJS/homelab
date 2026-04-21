# homelab

Ansible-driven infrastructure automation for a single-node Kubernetes homelab running on an NVIDIA Jetson Orin NX. Everything runs from Docker containers — no local Ansible install needed.

## Infrastructure

| Host | Hardware | OS | Kernel | Role |
|------|----------|----|--------|------|
| jetson | Seeed reComputer J4012 (Orin NX 16GB) | Ubuntu 20.04.6 LTS (L4T R35.5.0) | 5.10.192-tegra | k3s server, Tailscale exit node |

## Stack

- **k3s** (v1.34.5) — Lightweight Kubernetes with Flannel VXLAN + kube-proxy
- **FluxCD** — GitOps continuous delivery, watches `k8s/` in this repo
- **Tailscale** — Mesh VPN, exit node for LAN access, remote kubectl
- **GitHub Actions Runner Controller (ARC)** — Self-hosted ARM64 CI runners (`jetson-arm64`)

## Repository Structure

```
.
├── Dockerfile                          # Ansible runtime (Python 3.12, ansible-core <2.18)
├── Makefile                            # All commands run via Docker
├── entrypoint.sh                       # Docker entrypoint (vault password handling)
├── ansible/
│   ├── ansible.cfg                     # Ansible configuration
│   ├── vault.yml                       # Encrypted secrets (ansible-vault)
│   ├── vault.yml.example              # Vault template
│   ├── requirements.yml               # Ansible Galaxy collections
│   ├── site.yml                       # Full playbook: common → kernel-modules → tailscale → k3s → flux
│   ├── k3s.yml                        # k3s-only: common → kernel-modules → k3s
│   ├── tailscale.yml                  # Tailscale-only playbook
│   ├── flux.yml                       # FluxCD bootstrap playbook
│   ├── diagnose.yml                   # Networking diagnostics playbook
│   ├── inventory/
│   │   ├── hosts.yml                  # Host inventory
│   │   ├── group_vars/all.yml         # Shared variables (k3s version, timezone)
│   │   └── host_vars/jetson/vars.yml  # Jetson-specific variables
│   └── roles/
│       ├── common/                    # Base packages, sysctl, iptables-legacy, kernel modules
│       ├── kernel-modules/            # Compile missing Tegra kernel modules (see KERNEL.md)
│       ├── tailscale/                 # Install, configure, exit node NAT fix
│       ├── k3s/                       # Install/configure k3s, fetch kubeconfig
│       └── flux/                      # Bootstrap FluxCD, create ARC secrets
├── k8s/
│   ├── infrastructure/
│   │   ├── arc-controller/            # ARC controller HelmRelease
│   │   └── arc-runners/               # Runner scale set (jetson-arm64)
│   └── apps/                          # Application manifests (FluxCD-managed)
└── kubeconfig/                        # Fetched kubeconfigs (gitignored)
```

## Getting Started

### Prerequisites

- Docker
- SSH key access to the Jetson (via Tailscale or LAN)
- [1Password CLI](https://developer.1password.com/docs/cli/) (optional — for automatic vault password)

### Setup

```bash
# Build the Ansible Docker image
make build

# Setup vault secrets
make setup
vim ansible/vault.yml        # fill in your secrets
make vault-encrypt

# Verify SSH connectivity
make ping

# Full deploy (common + kernel-modules + tailscale + k3s + flux)
make deploy
```

### Vault Secrets

The vault file (`ansible/vault.yml`) stores three secrets:

| Variable | Purpose |
|----------|---------|
| `vault_become_pass` | sudo password for the Jetson |
| `vault_tailscale_authkey` | Tailscale auth key for node registration |
| `vault_github_token` | GitHub PAT for Flux bootstrap and ARC runners |

The GitHub PAT needs **Contents (read/write)** and **Administration (read/write)** on this repo.

Vault password resolution order:
1. `VAULT_PASSWORD` environment variable
2. 1Password CLI (`op read 'op://Private/jetson-ansible-playbook/password'`)
3. `.vault-password` file (gitignored)
4. Interactive prompt

### Available Commands

```
make build                # Build the Ansible Docker image
make deploy               # Run full site playbook (all roles)
make deploy-tailscale     # Run Tailscale-only playbook
make deploy-k3s           # Run k3s-only playbook
make deploy-k3s-clean     # Run k3s with clean reinstall
make deploy-flux          # Bootstrap FluxCD on the cluster
make diagnose             # Run networking diagnostics on the Jetson
make ping                 # Verify SSH connectivity to all hosts
make k c="get pods -A"    # Run kubectl against the k3s cluster
make lint                 # Lint playbooks and roles
make shell                # Open a shell in the Ansible container
make setup                # Setup vault secrets from template
make vault-encrypt        # Encrypt the vault file
make vault-edit           # Edit the encrypted vault file
make install-ca-cert      # Trust the homelab CA on your machine (macOS/Linux)
make kubeconfig-merge     # Merge homelab kubeconfig into ~/.kube/config
make clean                # Remove the Docker image
```

### Kubeconfig

After deploying k3s, the kubeconfig is fetched to `kubeconfig/jetson.yaml` with the Tailscale IP as the server address:

```bash
# Using the make shortcut (scoped KUBECONFIG, doesn't pollute your shell)
make k c="get nodes"
make k c="get pods -A"

# Or export it manually
export KUBECONFIG=$(pwd)/kubeconfig/jetson.yaml
kubectl get nodes
```

## Roles

### common

Base system setup applied to all hosts:
- Installs essential packages (curl, jq, open-iscsi, nfs-common, etc.)
- Ensures `iptables-legacy` is the active alternative (not nftables)
- Loads kernel modules (br_netfilter, overlay, iptables modules)
- Applies sysctl settings (IP forwarding, inotify limits, bridge netfilter)
- Sets timezone

### kernel-modules

Compiles missing netfilter/ipset kernel modules for the Tegra kernel. This is required because NVIDIA's stock kernel doesn't include several modules that Kubernetes networking needs. See [ansible/KERNEL.md](ansible/KERNEL.md) for the full story.

- Downloads L4T R35.5.0 BSP sources from NVIDIA
- Enables missing kernel configs (IP_SET, XT_MATCH_NFACCT, etc.)
- Compiles only the needed subdirectories using `make M=<dir> modules`
- Installs `.ko` files to `/lib/modules/` and runs `depmod`
- Loads modules and persists them across reboots
- Skips entirely on subsequent runs if modules already work

### tailscale

Installs and configures Tailscale:
- Adds Tailscale apt repo and installs the package
- Brings up Tailscale with auth key, exit node, and route advertisement
- **Exit node NAT fix**: Deploys a systemd service + timer that re-applies iptables MASQUERADE rules every 5 minutes (k3s/flannel clobbers `ts-postrouting`)

### k3s

Installs k3s using the official install script:
- Optionally uninstalls existing k3s for clean installs (`k3s_clean_install: true`)
- Deploys `/etc/rancher/k3s/config.yaml` with Flannel VXLAN, cluster/service CIDRs
- Adds Tailscale IP as a TLS SAN for remote kubectl access
- Disables Traefik by default (managed by Flux instead)
- Fetches kubeconfig locally with the Tailscale IP substituted as server address

### flux

Bootstraps FluxCD for GitOps:
- Installs the Flux CLI
- Bootstraps Flux pointing at `k8s/` in this repo
- Creates the ARC GitHub secret for runner authentication

## GitOps with FluxCD

Flux watches the `k8s/` directory in this repo and reconciles changes automatically:

- `k8s/infrastructure/` — Cluster infrastructure (ARC controller, runner scale sets)
- `k8s/apps/` — Application workloads

To deploy something new, add manifests to `k8s/apps/`, commit, and push. Flux picks it up.

## TLS / Certificate Management

The cluster uses a self-signed CA to issue wildcard certificates for `*.int.shankyjs.com`. cert-manager handles issuance and renewal automatically.

### How the CA was generated

```bash
# Generate a 4096-bit RSA CA keypair (valid 10 years)
openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
  -keyout ca.key -out ca.crt -days 3650 \
  -subj "/CN=shankyjs-homelab-ca/O=shankyjs-homelab"

# Store both in 1Password (item: ca_key_int_shankyjs_com)
op item edit ca_key_int_shankyjs_com \
  "credential[password]=$(cat ca.key)" \
  "certificate[password]=$(cat ca.crt)"

# Delete the private key from disk — it lives only in 1Password now
rm ca.key
```

The public cert is committed at `k8s/certs/ca.crt` for trust distribution. The private key **never** touches the repo.

### How it flows through the cluster

```
1Password (ca_key_int_shankyjs_com)
  └─ ExternalSecret (cert-manager/ca-key-secret) ── refreshes every 24h

## Internal DNS overrides

Some services (like Zot) are reachable via public DNS but must be accessed
through the internal Traefik IP from inside the cluster. We use k8s-gateway
to provide a split-horizon override so pods resolve the internal IP.

- Source: `k8s/infrastructure/k8s-gateway/deployment.yaml`
- Override: `zot.int.shankyjs.com -> 100.88.193.63`

Self-checks:

```
# Query internal DNS from a pod
kubectl -n arc-runners exec <pod> -- nslookup zot.int.shankyjs.com

# Validate TLS via the internal IP
kubectl -n arc-runners exec <pod> -- sh -c \
  'curl -vk https://zot.int.shankyjs.com/v2/_catalog \
    --resolve zot.int.shankyjs.com:443:100.88.193.63'
```
       └─ ClusterIssuer (selfsigned-ca)
            ├─ Certificate (traefik/wildcard-tls)   ── *.int.shankyjs.com, 1yr, auto-renew at 30d
            └─ Certificate (zot/wildcard-tls)       ── *.int.shankyjs.com, 1yr, auto-renew at 30d
```

The CA public cert is also distributed as a ConfigMap (`kube-system/homelab-ca-cert`) for containers that need to trust it (e.g. ARC DinD runners pushing to Zot).

### Trusting the CA on your machine

```bash
# macOS (adds to System Keychain) / Linux (update-ca-certificates)
scripts/install-ca-cert.sh
```

### 1Password item layout

| Item | Field | Contents |
|------|-------|----------|
| `ca_key_int_shankyjs_com` | `credential` | PEM-encoded CA private key |
| `ca_key_int_shankyjs_com` | `certificate` | PEM-encoded CA public certificate |

## Design Decisions

- **All Ansible runs happen in Docker** — No local Ansible install, no Python version conflicts, reproducible across machines
- **Ansible pinned to <2.18** — The Jetson runs Ubuntu 20.04 with Python 3.8; newer Ansible drops support for Python 3.8 on targets
- **Flannel + kube-proxy** over Calico eBPF — Calico requires ipset support which needed custom kernel modules anyway; Flannel works out of the box once the kernel modules are compiled
- **Single GitHub PAT** for both Flux and ARC — Simplifies secret management
- **Monorepo** — Ansible config, k8s manifests, and CI config all in one place
