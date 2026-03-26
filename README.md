# homelab

Ansible playbooks, IaC and more to install and configure my Homelab environment.

## Infrastructure

| Host | Hardware | OS | IP (Tailscale) | IP (LAN) | Role |
|------|----------|----|-----------------|-----------|------|
| jetson | NVIDIA Jetson Orin (aarch64) | Ubuntu 20.04 (Tegra) | 100.88.193.63 | 192.168.50.31 | k3s server, Tailscale exit node |

## Repository Structure

```
.
├── Dockerfile                   # Ansible runtime image
├── Makefile                     # All commands run via Docker
├── ansible/
│   ├── ansible.cfg              # Ansible configuration
│   ├── vault.yml                # Encrypted secrets (gitignored)
│   ├── vault.yml.example        # Vault template
│   ├── requirements.yml         # Ansible Galaxy collections
│   ├── inventory/
│   │   ├── hosts.yml            # Host inventory
│   │   ├── group_vars/
│   │   │   └── all.yml          # Shared variables
│   │   └── host_vars/
│   │       └── jetson/
│   │           └── vars.yml     # Jetson-specific variables
│   ├── roles/
│   │   ├── common/              # Base packages, sysctl, kernel modules
│   │   ├── tailscale/           # Install, configure, exit node NAT fix
│   │   └── k3s/                 # Install and configure k3s
│   ├── site.yml                 # Full playbook (all roles)
│   ├── tailscale.yml            # Tailscale-only playbook
│   └── k3s.yml                  # k3s-only playbook
├── kubeconfig/                  # Fetched kubeconfigs (gitignored)
└── .vault-password              # Vault password file (gitignored, optional)
```

## Getting Started

The only prerequisite is Docker. Everything runs inside a container.

```bash
# Build the Ansible Docker image
make build

# Setup vault secrets
make setup
vim ansible/vault.yml        # fill in your secrets
make vault-encrypt

# Optionally, skip password prompts by creating a vault password file
echo 'your-vault-password' > .vault-password

# Verify SSH connectivity
make ping

# Full setup (common + tailscale + k3s)
make deploy
```

### Available Commands

```
make help                 # Show all available commands
make build                # Build the Ansible Docker image
make ping                 # Verify SSH connectivity to all hosts
make deploy               # Run full site playbook
make deploy-tailscale     # Run Tailscale-only playbook
make deploy-k3s           # Run k3s-only playbook
make deploy-k3s-clean     # Run k3s with clean reinstall
make lint                 # Lint playbooks and roles
make shell                # Open a shell in the Ansible container
make setup                # Setup vault secrets from template
make vault-encrypt        # Encrypt the vault file
make vault-edit           # Edit the encrypted vault file
make clean                # Remove the Docker image
```

### Use Kubeconfig

After running the k3s playbook, the kubeconfig is fetched to `kubeconfig/jetson.yaml`:

```bash
export KUBECONFIG=$(pwd)/kubeconfig/jetson.yaml
kubectl get nodes
```

## Roles

### common
Base system setup applied to all hosts:
- Installs essential packages (curl, jq, open-iscsi, nfs-common, etc.)
- Loads kernel modules (br_netfilter, overlay, iptables modules)
- Applies sysctl settings (IP forwarding, inotify limits, bridge netfilter)

### tailscale
Installs and configures Tailscale:
- Adds Tailscale apt repo and installs the package
- Brings up Tailscale with auth key, exit node, and route advertisement
- **Exit node NAT fix**: Deploys a systemd service + timer that re-applies iptables MASQUERADE rules every 5 minutes, fixing the issue where k3s/flannel clobbers `ts-postrouting`

### k3s
Installs k3s using the official install script:
- Optionally uninstalls existing k3s for clean installs
- Deploys `/etc/rancher/k3s/config.yaml` with cluster settings
- Disables Traefik by default (for FluxCD-managed ingress later)
- Fetches kubeconfig locally with the Tailscale IP substituted
