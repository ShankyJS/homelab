#!/bin/bash
# Set LOCALVERSION in kernel config to match running kernel
# Requires: KERNEL_SRC_DIR environment variable
set -euo pipefail

cd "$KERNEL_SRC_DIR"

# Extract the local version suffix (e.g., "-tegra" from "5.10.192-tegra")
KVER=$(uname -r)
BASE_VER=$(make -s kernelversion 2>/dev/null || echo "unknown")
LOCAL_VER="${KVER#$BASE_VER}"
echo "Running kernel: $KVER, Base: $BASE_VER, LocalVersion: $LOCAL_VER"
scripts/config --disable LOCALVERSION_AUTO
scripts/config --set-str LOCALVERSION "$LOCAL_VER"
