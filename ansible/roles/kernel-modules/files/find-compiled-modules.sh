#!/bin/bash
# Find compiled kernel modules in the kernel source tree
# Requires: BUILD_DIR (kernel source root), BUILD_SUBDIRS (space-separated) environment variables
set -euo pipefail

KVER=$(uname -r)
echo "Source dir: $BUILD_DIR"
echo "Target dir: /lib/modules/$KVER"
echo ""

# List the specific modules we need
for mod in ip_set ip_set_hash_ip ip_set_hash_net ip_set_hash_netportnet xt_CT xt_rpfilter xt_nfacct ipt_rpfilter ip6t_rpfilter nfnetlink_log nfnetlink_acct; do
  found=""
  for subdir in $BUILD_SUBDIRS; do
    match=$(find "$BUILD_DIR/$subdir" -name "${mod}.ko" 2>/dev/null | head -1)
    if [ -n "$match" ]; then
      found="$match"
      break
    fi
  done
  if [ -n "$found" ]; then
    echo "FOUND: $mod -> $found"
  else
    echo "NOT FOUND: $mod"
  fi
done
