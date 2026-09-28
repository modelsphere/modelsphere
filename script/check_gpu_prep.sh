#!/usr/bin/env bash
#
# check_gpu_prep.sh — 只读校验 gpu-prep 做过的每一项(与 nvidia_audit.yaml 的 gpu-prep 一一对应)
#
# 用途：部署前 / 重启后确认 GPU 节点仍处于 prep 之后的状态。只读，不改任何东西。
#       每加一项 gpu-prep 动作，这里就加一条对应检查 —— audit 与 prep 靠这个文件保持同步。
#
# 重启后应当全部仍为 PASS：ACS 由 disable-acs.service 开机重清（setpci 是寄存器写、
# 重启必复原），内核模块靠 /etc/modules-load.d 持久化。
#
# 用法（节点本机 root 执行，或由 nvidia_audit.yaml 下发）：
#   bash check_gpu_prep.sh
#
set -u

fail=0
pass() { printf '  [PASS] %s\n' "$*"; }
info() { printf '  [INFO] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail + 1)); }

# 编进内核的(=y)不进 /proc/modules,用 /sys/module/<name> 兜底。
loaded_mods=" $(awk '{print $1}' /proc/modules 2>/dev/null | tr '\n' ' ') "
is_loaded() {
    case "$loaded_mods" in
    *" $1 "*) return 0 ;;
    esac
    [ -d "/sys/module/$1" ]
}

# Same rule as nvidia_audit.yaml: auto = ib with RDMA devices, none without.
RDMA_FABRIC="${RDMA_FABRIC:-auto}"
if [ "$RDMA_FABRIC" = auto ]; then
    if [ -n "$(ls -A /sys/class/infiniband 2>/dev/null)" ]; then RDMA_FABRIC=ib; else RDMA_FABRIC=none; fi
fi
rdma() { [ "$RDMA_FABRIC" != none ]; }

echo ""
echo "========================================="
echo " GPU Prep Verification for $(hostname)"
echo "========================================="

# ① RDMA 内核模块 —— rdma-shared-dev-plugin 建 device spec 要求全套 char 设备
echo "  rdma fabric: $RDMA_FABRIC"
[ -r /proc/modules ] || bad "/proc/modules 不可读 —— 下面所有模块检查结果不可信"
if ! rdma; then
    echo "-- rdma --"
    info "no RDMA fabric: rdma modules, /dev/infiniband, NCCL_IB_HCA and nvidia_peermem not applicable"
else
echo "-- rdma kernel modules --"
for m in rdma_ucm ib_umad ib_uverbs; do
    if is_loaded "$m"; then
        pass "$m loaded"
    else
        bad "$m NOT loaded"
    fi
done
if [ -f /etc/modules-load.d/rdma.conf ]; then
    pass "/etc/modules-load.d/rdma.conf : $(tr '\n' ' ' < /etc/modules-load.d/rdma.conf)"
else
    bad "/etc/modules-load.d/rdma.conf missing (modules will not survive reboot)"
fi

echo "-- /dev/infiniband char devices --"
ib_devs=$(ls /dev/infiniband 2>/dev/null | tr '\n' ' ')
echo "  ${ib_devs:-(empty)}"
for pat in uverbs rdma_cm umad; do
    case "$ib_devs" in
    *"$pat"*) pass "$pat present" ;;
    *) bad "$pat missing → plugin will report 'missing RDMA device spec'" ;;
    esac
done

# ② NCCL_IB_HCA 名单 —— kimi manifest 直接 source 这个 hostPath 文件
echo "-- NCCL_IB_HCA (/etc/gpu-node/nccl-ib.env) --"
if [ -f /etc/gpu-node/nccl-ib.env ]; then
    hcas=$(grep -m1 '^NCCL_IB_HCA=' /etc/gpu-node/nccl-ib.env 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [ -n "$hcas" ]; then
        pass "NCCL_IB_HCA=$hcas"
        # 名单是 prep 时算的，链路可能之后掉了 —— 逐口复查
        for dev in $(echo "$hcas" | tr ',' ' '); do
            st=$(awk '{print $2}' "/sys/class/infiniband/$dev/ports/1/state" 2>/dev/null)
            rt=$(awk '{print $1}' "/sys/class/infiniband/$dev/ports/1/rate" 2>/dev/null)
            if [ "$st" = "ACTIVE" ]; then
                pass "$dev state=$st rate=${rt:-?}"
            else
                bad "$dev state=${st:-NOT FOUND} — 名单里的口现在不可用"
            fi
        done
    else
        bad "/etc/gpu-node/nccl-ib.env has no NCCL_IB_HCA line"
    fi
else
    bad "/etc/gpu-node/nccl-ib.env missing (run make gpu-prep)"
fi
fi  # rdma

# ③ NVIDIA 内核模块 —— nvidia_peermem 是 GPUDirect RDMA 的开关
echo "-- nvidia kernel modules --"
mods="nvidia nvidia_uvm"; rdma && mods="$mods nvidia_peermem"
for m in $mods; do
    if is_loaded "$m"; then
        pass "$m loaded"
    else
        bad "$m NOT loaded"
    fi
done
if ! rdma; then
    :
elif [ -f /etc/modules-load.d/nvidia-peermem.conf ]; then
    pass "/etc/modules-load.d/nvidia-peermem.conf : $(tr '\n' ' ' < /etc/modules-load.d/nvidia-peermem.conf)"
else
    bad "/etc/modules-load.d/nvidia-peermem.conf missing (modules will not survive reboot)"
fi

# ④ Persistence mode
echo "-- persistence mode --"
if command -v nvidia-smi &> /dev/null; then
    pm=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ' ')
    case "$pm" in
    *Disabled*) bad "persistence mode: $pm" ;;
    "") bad "persistence mode: nvidia-smi returned nothing" ;;
    *) pass "persistence mode: $pm" ;;
    esac
else
    bad "nvidia-smi not found on host"
fi

# ⑤ Fabric Manager —— 只有 NVSwitch / HGX 机器需要
echo "-- fabric manager --"
if [ -x /usr/bin/nv-fabricmanager ]; then
    fm=$(systemctl is-active nvidia-fabricmanager 2>/dev/null)
    if [ "$fm" = "active" ]; then
        pass "nvidia-fabricmanager: active"
    else
        bad "nvidia-fabricmanager installed but ${fm:-inactive}"
    fi
else
    info "nv-fabricmanager not installed (expected on non-NVSwitch hosts)"
fi

# ⑥ nvidia-cdi-refresh —— 与 GPU Operator 冲突，必须关掉
echo "-- nvidia-cdi-refresh.service --"
cdi=$(systemctl is-enabled nvidia-cdi-refresh.service 2>/dev/null)
if [ "$cdi" = "enabled" ]; then
    bad "nvidia-cdi-refresh.service is ENABLED (conflicts with GPU Operator)"
else
    pass "nvidia-cdi-refresh.service: ${cdi:-not installed}"
fi

# ⑦ PCIe ACS —— 开着会把 P2P DMA 拽进 IOMMU，GPUDirect 吞吐直接塌
echo "-- pcie acs --"
acs=$(lspci -vvv 2>/dev/null | grep -c 'ACSCtl.*SrcValid+')
# 两条都要：现在是清的（本次生效）+ unit 已 enable（重启后还会被清）。
# 只看前一条分不出「清了但下次重启会回来」和「已经固化」—— 两种状态给出同一个 0。
acs_unit=$(systemctl is-enabled disable-acs.service 2>/dev/null || echo missing)
if [ "$acs" -eq 0 ]; then
    pass "acs_srcvalid=0"
else
    bad "acs_srcvalid=$acs — GDR 会挂或静默死锁，重跑 make gpu-prep"
fi
if [ "$acs_unit" = enabled ]; then
    pass "disable-acs.service enabled（重启后自动重清）"
else
    bad "disable-acs.service=$acs_unit — 重启后 ACS 会复原，跑 make gpu-prep 装上"
fi

echo "-----------------------------------------"
if [ "$fail" -eq 0 ]; then
    echo "RESULT: ALL PASS"
else
    echo "RESULT: $fail check(s) FAILED"
fi
echo "========================================="

# 退出码即结论 —— ssh 直接跑、CI、ansible 读 .rc 都靠它,不用去 grep 上面的文字。
# ansible 那边 audit play 挂了 failed_when: false,非零不会让 play 红掉,只是把结论带出去。
[ "$fail" -eq 0 ] || exit 1
exit 0
