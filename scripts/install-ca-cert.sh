#!/usr/bin/env bash
# Install the homelab self-signed CA certificate into the local trust store.
# Supports macOS (Keychain) and Linux (update-ca-certificates).
#
# Usage: scripts/install-ca-cert.sh [path-to-ca.crt]
# Default: k8s/certs/ca.crt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CA_CERT="${1:-${REPO_ROOT}/k8s/certs/ca.crt}"

if [ ! -f "${CA_CERT}" ]; then
  echo "Error: CA certificate not found at ${CA_CERT}"
  echo "Generate it first (see Phase 1A instructions)."
  exit 1
fi

echo "Installing CA certificate: ${CA_CERT}"

case "$(uname -s)" in
  Darwin)
    echo "Detected macOS — adding to System Keychain (requires sudo)..."
    sudo security add-trusted-cert -d -r trustRoot \
      -k /Library/Keychains/System.keychain \
      "${CA_CERT}"
    echo "Done. The CA cert is now trusted system-wide on macOS."
    echo "You may need to restart browsers for them to pick up the new cert."
    ;;
  Linux)
    echo "Detected Linux — adding to system CA certificates (requires sudo)..."
    sudo cp "${CA_CERT}" /usr/local/share/ca-certificates/homelab-ca.crt
    sudo update-ca-certificates
    echo "Done. The CA cert is now trusted system-wide on Linux."
    ;;
  *)
    echo "Unsupported OS: $(uname -s)"
    echo "Manually install ${CA_CERT} into your system's trust store."
    exit 1
    ;;
esac
