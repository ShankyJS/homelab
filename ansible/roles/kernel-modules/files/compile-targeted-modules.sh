#!/bin/bash
# Compile specific kernel module subdirectories using make M= (produces .ko files)
# Requires: KERNEL_SRC_DIR, BUILD_SUBDIRS (space-separated) environment variables
set -euo pipefail

cd "$KERNEL_SRC_DIR"

NPROC=$(nproc)

echo "=== Building kernel modules from subdirectories ==="
echo "Using $NPROC parallel jobs"
echo ""

for subdir in $BUILD_SUBDIRS; do
  if [ -d "$subdir" ]; then
    echo "--- Building M=$subdir ---"
    make -j"$NPROC" M="$subdir" modules 2>&1
    # Count .ko files produced
    count=$(find "$subdir" -name "*.ko" 2>/dev/null | wc -l)
    echo "--- Done: $subdir ($count .ko files) ---"
    echo ""
  else
    echo "WARN: directory $subdir not found, skipping"
  fi
done

echo "=== All builds complete ==="
echo ""
echo "=== .ko files produced ==="
for subdir in $BUILD_SUBDIRS; do
  find "$subdir" -name "*.ko" 2>/dev/null | sort
done
