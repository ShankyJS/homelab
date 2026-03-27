#!/bin/bash
# Install compiled kernel modules from source tree to running kernel
# Requires: BUILD_DIR (kernel source root), BUILD_SUBDIRS (space-separated) environment variables
set -euo pipefail

KVER=$(uname -r)
TARGET="/lib/modules/$KVER"

for mod in ip_set ip_set_hash_ip ip_set_hash_net ip_set_hash_netportnet xt_CT xt_rpfilter xt_nfacct ipt_rpfilter ip6t_rpfilter nfnetlink_log nfnetlink_acct; do
  # Find the .ko file in the build subdirectories
  src=""
  for subdir in $BUILD_SUBDIRS; do
    match=$(find "$BUILD_DIR/$subdir" -name "${mod}.ko" 2>/dev/null | head -1)
    if [ -n "$match" ]; then
      src="$match"
      break
    fi
  done

  if [ -z "$src" ]; then
    echo "SKIP (not built): $mod"
    continue
  fi

  # Compute relative path from kernel source root for target install path
  # e.g., net/netfilter/ipset/ip_set.ko -> kernel/net/netfilter/ipset/ip_set.ko
  rel_path="${src#$BUILD_DIR/}"
  target_path="$TARGET/kernel/$rel_path"
  target_dir=$(dirname "$target_path")

  mkdir -p "$target_dir"
  if [ ! -f "$target_path" ] || [ "$src" -nt "$target_path" ]; then
    echo "Installing: $mod -> kernel/$rel_path"
    cp "$src" "$target_path"
  else
    echo "Already exists: $mod"
  fi
done
