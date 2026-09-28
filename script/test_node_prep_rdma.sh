#!/usr/bin/env bash
#
# test_node_prep_rdma.sh — scenario tests for node_prep_rdma.sh (runs anywhere,
# touches no real hardware).
#
# Method: build a fake /sys/class/infiniband tree in a temporary directory and
# point the script at it with TESTROOT, so port selection -- link_layer, state,
# rate, the netdev whitelist -- runs for real on a machine with no RDMA NIC.
# modprobe is shimmed; the two files the script writes land under TESTROOT.
#
# Usage: bash script/test_node_prep_rdma.sh
#
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/node_prep_rdma.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     want: %s\n     got:  %s\n' "$1" "$2" "$3"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# port <root> <dev> <link_layer> <state> <rate> [netdev]
port() {
  local d="$1/sys/class/infiniband/$2"
  mkdir -p "$d/ports/1" "$d/device/net"
  printf '%s\n' "$3" > "$d/ports/1/link_layer"
  printf 'x: %s\n' "$4" > "$d/ports/1/state"      # sysfs is "4: ACTIVE"
  printf '%s Gb/sec (4X HDR)\n' "$5" > "$d/ports/1/rate"
  [ -n "${6:-}" ] && mkdir -p "$d/device/net/$6"
  return 0
}

newroot() {
  ROOT=$(mktemp -d)
  mkdir -p "$ROOT/sys/class/infiniband" "$ROOT/bin"
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/modprobe"; chmod +x "$ROOT/bin/modprobe"
}

# run <FABRIC> [IFNAMES] [RATE_MIN] -> sets RC, LIST
run() {
  OUT=$(PATH="$ROOT/bin:$PATH" TESTROOT="$ROOT" NO_REUSE_DEPLOY_ENV=1 \
        FABRIC="$1" IFNAMES="${2:-}" RATE_MIN="${3:-100}" \
        bash "$SUT" 2>&1)
  RC=$?
  if [ -f "$ROOT/etc/gpu-node/nccl-ib.env" ]; then
    LIST=$(cut -d= -f2 < "$ROOT/etc/gpu-node/nccl-ib.env")
  else
    LIST="<no file>"
  fi
}

echo "1. InfiniBand fabric, FABRIC=ib"
newroot
port "$ROOT" mlx5_0 InfiniBand ACTIVE 200
port "$ROOT" mlx5_1 InfiniBand ACTIVE 200
run ib
check "exit code" 0 "$RC"
check "port list" "mlx5_0,mlx5_1" "$LIST"
check "modules persisted" "rdma_ucm ib_umad ib_uverbs" "$(tr '\n' ' ' < "$ROOT/etc/modules-load.d/rdma.conf" | sed 's/ $//')"

echo "2. RoCE fabric, FABRIC=ib -- what auto guesses, and it guesses wrong"
newroot
port "$ROOT" mlx5_0 Ethernet ACTIVE 200 enp234s0np0
run ib
check "exit code is 0, not a failed run" 0 "$RC"
check "no port list written" "<no file>" "$LIST"
check "modules persisted anyway" "rdma_ucm ib_umad ib_uverbs" "$(tr '\n' ' ' < "$ROOT/etc/modules-load.d/rdma.conf" | sed 's/ $//')"
case "$OUT" in *"no usable InfiniBand port"*) ok "says why" ;; *) bad "says why" "a warning" "$OUT" ;; esac

echo "3. RoCE fabric, FABRIC=roce"
newroot
port "$ROOT" mlx5_0 Ethernet ACTIVE 200 enp234s0np0
run roce
check "exit code" 0 "$RC"
check "port list" "mlx5_0" "$LIST"

echo "4. RoCE fabric with a non-fabric 200G NIC, narrowed by IFNAMES"
newroot
port "$ROOT" mlx5_0 Ethernet ACTIVE 200 enp234s0np0   # the fabric
port "$ROOT" mlx5_1 Ethernet ACTIVE 200 eno1          # plain data NIC, same speed
run roce
check "without IFNAMES both are kept" "mlx5_0,mlx5_1" "$LIST"
newroot
port "$ROOT" mlx5_0 Ethernet ACTIVE 200 enp234s0np0
port "$ROOT" mlx5_1 Ethernet ACTIVE 200 eno1
run roce enp234s0np0
check "with IFNAMES only the fabric port" "mlx5_0" "$LIST"

echo "5. down and degraded ports are excluded"
newroot
port "$ROOT" mlx5_0 InfiniBand ACTIVE 200
port "$ROOT" mlx5_1 InfiniBand DOWN   200
port "$ROOT" mlx5_2 InfiniBand ACTIVE 40     # negotiated below line rate
run ib
check "port list" "mlx5_0" "$LIST"
newroot
port "$ROOT" mlx5_0 InfiniBand ACTIVE 200
port "$ROOT" mlx5_1 InfiniBand ACTIVE 40
run ib "" 25
check "RATE_MIN=25 lets the slow one back in" "mlx5_0,mlx5_1" "$LIST"

echo "6. an existing list is left alone when no port qualifies"
newroot
mkdir -p "$ROOT/etc/gpu-node"
echo "NCCL_IB_HCA=mlx5_9" > "$ROOT/etc/gpu-node/nccl-ib.env"
port "$ROOT" mlx5_0 Ethernet ACTIVE 200 eno1
run ib
check "exit code" 0 "$RC"
check "previous list untouched" "mlx5_9" "$LIST"

echo "7. FABRIC=none does nothing, FABRIC=typo fails loudly"
newroot
run none
check "none: exit code" 0 "$RC"
check "none: writes no module conf" "absent" "$([ -f "$ROOT/etc/modules-load.d/rdma.conf" ] && echo present || echo absent)"
newroot
run bogus
check "typo: exit code" 1 "$RC"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
