# Tegra Kernel Module Fixes for Kubernetes

This document explains the kernel module issues encountered when running Kubernetes (k3s) on the NVIDIA Jetson Orin NX and how the `kernel-modules` Ansible role fixes them.

## The Problem

NVIDIA's stock Tegra kernel (`5.10.192-tegra`, L4T R35.5.0 / JetPack 5.1.3) is missing several netfilter and ipset kernel modules that Kubernetes networking requires. This causes a complete failure of ClusterIP service routing.

### Symptoms

- All pods stuck in `Running` but `0/1 Ready`
- CoreDNS logs: `dial tcp 10.43.0.1:443: i/o timeout`
- kube-proxy logs (every 30 seconds):
  ```
  Failed to execute iptables-restore
  exit status 2: iptables-restore v1.8.4 (legacy):
  Couldn't load match 'nfacct': No such file or directory
  ```
- `iptables -t nat -L KUBE-SERVICES` shows an empty chain (zero rules)
- `ipset list -name` returns `Kernel error received: Invalid argument`

### Root Cause Chain

1. **`xt_nfacct` kernel module missing** — kube-proxy (in k3s v1.34.5) uses the `nfacct` iptables match for traffic accounting. The Tegra kernel doesn't ship `xt_nfacct.ko`.

2. **`iptables-restore` fails atomically** — When kube-proxy calls `iptables-restore` with its full ruleset and any single rule references a missing module, the *entire* restore is rejected. It doesn't skip the bad rule — it drops everything.

3. **Zero KUBE-SERVICES NAT rules get installed** — Since the restore fails completely, no ClusterIP DNAT rules exist. Services like `10.43.0.1:443` (kubernetes API) and `10.43.0.10:53` (kube-dns) have no backing iptables rules.

4. **Pods can't reach the API server via ClusterIP** — CoreDNS, metrics-server, and every other pod that talks to the Kubernetes API via its ClusterIP gets `i/o timeout`. Readiness probes fail. Nothing works.

5. **`ip_set` modules also broken** — The Tegra kernel's ipset implementation returns `Invalid argument` for any `ipset` command. This would block Calico (if used) and any network policy that relies on ipsets.

### What Was NOT the Problem

These were all investigated and ruled out:

- **iptables mode** — Already set to `iptables-legacy` (not nftables). Not the issue.
- **Core netfilter modules** — `br_netfilter`, `overlay`, `ip_tables`, `iptable_nat`, `nf_nat`, `nf_conntrack`, `xt_MASQUERADE` all load fine.
- **Flannel** — Working correctly. Pods get IPs from the `10.42.0.0/16` CIDR. The `subnet.env` file exists. Pod-to-pod networking is fine.
- **`nf_nat_masquerade_ipv4` / `nf_conntrack_ipv4` missing** — These are folded into `nf_nat` / `nf_conntrack` in kernel 5.x. Expected behavior.

### Calico eBPF Attempt

Before finding the kernel module fix, we attempted to bypass kube-proxy entirely by switching to Calico with eBPF dataplane mode. This failed because Calico's Felix component also requires `ipset` — even in eBPF mode, Felix uses ipsets as a fallback for certain iptables operations. Felix crashed in an infinite loop on `ipset list -name` returning `Invalid argument`.

## The Fix

Compile the missing kernel modules from NVIDIA's L4T BSP (Board Support Package) source directly on the Jetson. No full kernel recompile or reboot required.

### How It Works

The `kernel-modules` Ansible role (`ansible/roles/kernel-modules/`) automates this process:

1. **Downloads L4T BSP sources** (~1.8GB) from NVIDIA's developer site
2. **Extracts the kernel source** from the BSP archive
3. **Copies the running kernel config** from `/proc/config.gz`
4. **Enables the missing kernel configs**:
   ```
   IP_SET, IP_SET_HASH_IP, IP_SET_HASH_NET, IP_SET_HASH_NETPORTNET
   NETFILTER_XT_TARGET_CT, NETFILTER_XT_MATCH_RPFILTER, NETFILTER_XT_MATCH_NFACCT
   IP_NF_MATCH_RPFILTER, IP6_NF_MATCH_RPFILTER
   NETFILTER_NETLINK_LOG, NETFILTER_NETLINK_ACCT
   ```
5. **Sets LOCALVERSION** to `-tegra` to match the running kernel's version string
6. **Compiles only the needed subdirectories** using `make M=<dir> modules`:
   - `net/netfilter` — ipset, xt_nfacct, xt_CT, xt_rpfilter, nfnetlink_log, nfnetlink_acct
   - `net/ipv4/netfilter` — ipt_rpfilter
   - `net/ipv6/netfilter` — ip6t_rpfilter
7. **Installs the `.ko` files** to `/lib/modules/5.10.192-tegra/kernel/...`
8. **Runs `depmod -a`** to rebuild the module dependency tree
9. **Loads the modules** with `modprobe` and persists them in `/etc/modules-load.d/`

### Why `make M=<dir> modules` Instead of `make modules`

A full `make modules` builds every kernel module (~5000+) and takes over 30 minutes on the Orin NX's 8 ARM64 cores — too long for an Ansible timeout.

The `make M=net/netfilter modules` syntax tells kbuild to compile and **link `.ko` files** for only that subdirectory. This takes ~2-5 minutes.

Note: `make net/netfilter/` (without `M=` and `modules`) only produces `.o` object files — it does NOT link them into loadable `.ko` modules. This was a pitfall we hit during development.

### Idempotency

The role is idempotent. On subsequent runs:
- If the modules are already loaded and working (`modprobe` + `ipset list -name` succeed), the entire build is skipped
- If the BSP sources are already downloaded/extracted, those steps are skipped
- Only new/missing `.ko` files are copied to `/lib/modules/`

### References

- [NVIDIA Developer Forums: Successful kernel tweaks to support Kubernetes and Calico on the Jetson Orin](https://forums.developer.nvidia.com/t/successful-kernel-tweaks-to-support-kubernetes-and-calico-on-the-jetson-orin-nan/358833) — The community post that documented this approach
- [L4T R35.5.0 BSP Sources](https://developer.nvidia.com/downloads/embedded/l4t/r35_release_v5.0/sources/public_sources.tbz2) — NVIDIA's official kernel source for JetPack 5.1.3

## Board Details

| Field | Value |
|-------|-------|
| Board | Seeed reComputer J4012 |
| SoC | NVIDIA Jetson Orin NX 16GB |
| OS | Ubuntu 20.04.6 LTS |
| L4T | R35.5.0 (JetPack 5.1.3) |
| Kernel | 5.10.192-tegra |
| Architecture | aarch64 (ARM64) |
