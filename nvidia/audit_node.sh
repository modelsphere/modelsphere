#!/bin/bash
#
# 退出码:发现真问题(驱动没加载 / cdi-refresh 开着 / HCA 没有 netdev)返回 1,
# 否则 0。注意「没装 Fabric Manager」「没装 MOFED」这类在非 NVSwitch / inbox 驱动
# 机器上是正常的,不计入错误 —— 只数确定有害的三项。
errors=0

echo ""
echo "========================================="
echo " GPU Audit Report for $(hostname)"
echo "========================================="

# 0. OS & Kernel Version
if [ -f /etc/os-release ]; then
    OS_VERSION=$(source /etc/os-release && echo "$PRETTY_NAME")
else
    OS_VERSION="Unknown OS"
fi
KERNEL_VERSION=$(uname -r)

echo "[+] OS Version            : $OS_VERSION"
echo "[+] Kernel Version        : $KERNEL_VERSION"
echo "-----------------------------------------"

# 1. NVIDIA Driver Version & Persistence Mode
SMI_BIN=""
if command -v nvidia-smi &> /dev/null; then
    SMI_BIN="nvidia-smi"
elif [ -f /run/nvidia/driver/bin/nvidia-smi ]; then
    SMI_BIN="/run/nvidia/driver/bin/nvidia-smi"
fi

if lsmod | grep -q "^nvidia"; then
    if dpkg -l 2>/dev/null | grep -qE "nvidia-driver-[0-9]+|nvidia-dkms-[0-9]+|cuda-drivers"; then
        ORIGIN="Host OS Package (apt)"
    elif [ -f /usr/bin/nvidia-uninstall ]; then
        ORIGIN="Host OS Manual (.run)"
    else
        ORIGIN="GPU Operator (Containerized)"
    fi

    if [ -n "$SMI_BIN" ]; then
        DRIVER_VERSION=$($SMI_BIN --query-gpu=driver_version --format=csv,noheader | head -n 1)
        echo "[+] NVIDIA Driver         : Loaded (Origin: $ORIGIN, Version: $DRIVER_VERSION)"

        PM_MODE=$($SMI_BIN --query-gpu=persistence_mode --format=csv,noheader | head -n 1)
        echo "[+] Persistence Mode      : $PM_MODE"
    else
        echo "[+] NVIDIA Driver         : Loaded (Origin: $ORIGIN, Version: Unknown - smi not found)"
        echo "[+] Persistence Mode      : N/A"
    fi

    if [ -n "$SMI_BIN" ]; then
        GPU_INFO=$($SMI_BIN --query-gpu=name --format=csv,noheader | sort | uniq -c | sed 's/^[ \t]*//')
        echo "[+] GPU Hardware          : $GPU_INFO"

        MIG_MODE=$($SMI_BIN --query-gpu=mig.mode.current --format=csv,noheader | head -n 1 2>/dev/null || echo "N/A")
        echo "[+] MIG Mode (Current)    : $MIG_MODE"
    fi
else
    echo "[-] NVIDIA Driver         : NOT Loaded"
    echo "[-] Persistence Mode      : N/A"
    echo "[-] GPU Hardware          : N/A"
    echo "[-] MIG Mode (Current)    : N/A"
    errors=$((errors + 1))
fi

# 2. Fabric Manager Version
if command -v nv-fabricmanager &> /dev/null; then
    FM_VERSION=$(nv-fabricmanager --version 2>/dev/null | grep -i 'version' | head -n1)
    echo "[+] Fabric Manager        : ${FM_VERSION:-Installed but version unknown}"
elif dpkg -l | grep -q "nvidia-fabricmanager"; then
    FM_PKG=$(dpkg -l | grep nvidia-fabricmanager | awk '{print $3}' | head -n1)
    echo "[+] Fabric Manager        : $FM_PKG (via dpkg)"
else
    echo "[-] Fabric Manager        : Not Installed"
fi

# 3. Container Toolkit Version
if command -v nvidia-ctk &> /dev/null; then
    CTK_VERSION=$(nvidia-ctk --version 2>/dev/null | head -n 1)
    echo "[+] Container Toolkit     : $CTK_VERSION"
elif dpkg -l | grep -q "nvidia-container-toolkit"; then
    CTK_PKG=$(dpkg -l | grep nvidia-container-toolkit | awk '{print $3}' | head -n1)
    echo "[+] Container Toolkit     : $CTK_PKG (via dpkg)"
else
    echo "[-] Container Toolkit     : Not Installed"
fi

# 3.5 Host CDI Refresh Service Check
if systemctl is-enabled nvidia-cdi-refresh.service &> /dev/null; then
    echo "[!] WARNING               : nvidia-cdi-refresh.service is ENABLED on host!"
    echo "                            (Disable it with: systemctl disable --now nvidia-cdi-refresh.service)"
    errors=$((errors + 1))
else
    echo "[+] Host CDI Refresh      : Disabled or Not Installed (Safe for GPU Operator)"
fi

# 4. Containerd Version
if command -v containerd &> /dev/null; then
    CONTAINERD_VERSION=$(containerd --version 2>/dev/null | awk '{print $3}')
    echo "[+] Containerd Version    : $CONTAINERD_VERSION"
else
    echo "[-] Containerd Version    : Not Installed"
fi

# 5. Mellanox / RDMA Networking
echo "-----------------------------------------"
if command -v lspci &> /dev/null; then
    MLNX_DEVICES=$(lspci -nn | grep -i mellanox)
    if [ -n "$MLNX_DEVICES" ]; then
        MLNX_COUNT=$(echo "$MLNX_DEVICES" | wc -l | xargs)
        echo "[+] Mellanox Devices      : $MLNX_COUNT found"

        if lsmod | grep -q "^mlx5_core"; then
            MLX_VER=$(modinfo mlx5_core 2>/dev/null | grep '^version:' | awk '{print $2}')
            MLX_PATH=$(modinfo mlx5_core 2>/dev/null | grep '^filename:' | awk '{print $2}')

            # Distinguish origin based on module path and ofed_info presence
            if echo "$MLX_PATH" | grep -q "/kernel/drivers/"; then
                ORIGIN="Inbox/Native OS"
            elif command -v ofed_info &> /dev/null; then
                ORIGIN="Host MOFED Installation"
            else
                ORIGIN="Network Operator (Containerized)"
            fi

            echo "[+] mlx5_core Module      : Loaded (Origin: $ORIGIN, Version: ${MLX_VER:-Unknown})"
        else
            echo "[-] mlx5_core Module      : NOT Loaded"
        fi

        if command -v ofed_info &> /dev/null; then
            OFED_VER=$(ofed_info -s 2>/dev/null)
            echo "[+] Host MOFED Version    : $OFED_VER"
        else
            echo "[-] Host MOFED Version    : Not Installed (Using OS Inbox drivers)"
        fi

        echo "$MLNX_DEVICES" | sed 's/^/    - /'
    else
        echo "[-] Mellanox Devices      : None Found"
    fi
else
    echo "[-] Mellanox Devices      : Unknown (lspci not found)"
fi

if command -v rdma &> /dev/null; then
    RDMA_LINKS=$(rdma link 2>/dev/null | awk '{print $2, "->", $4}')
    if [ -n "$RDMA_LINKS" ]; then
        echo "[+] RDMA Links            :"
        echo "$RDMA_LINKS" | sed 's/^/    - /'
    fi
elif command -v ibv_devinfo &> /dev/null; then
    IBV_DEVS=$(ibv_devinfo --list 2>/dev/null | grep -v "HCAs found" | tr -d '\t')
    if [ -n "$IBV_DEVS" ]; then
        echo "[+] RDMA Devices (ibv)    :"
        echo "$IBV_DEVS" | sed 's/^/    - /'
    fi
fi

echo "-----------------------------------------"
echo "[+] K8s Device Plugin Check :"
for d in /sys/class/infiniband/*; do
    [ -e "$d" ] || continue
    dev=$(basename "$d")
    ll=$(cat "$d"/ports/1/link_layer 2>/dev/null || echo "Unknown")
    st=$(cat "$d"/ports/1/state 2>/dev/null | awk '{print $2}')
    nd=$(ls "$d"/device/net 2>/dev/null | head -1)

    if [ -z "$nd" ]; then
        echo "    - [FAIL] $dev ($ll, $st) -> NO NETDEV (Plugin linkTypes will expose '0')"
        errors=$((errors + 1))
    else
        echo "    - [PASS] $dev ($ll, $st) -> Netdev: $nd (Plugin should discover this)"
    fi
done

echo "-----------------------------------------"
if [ "$errors" -eq 0 ]; then
    echo "RESULT: OK"
else
    echo "RESULT: $errors problem(s) found"
fi
echo "========================================="

[ "$errors" -eq 0 ] || exit 1
exit 0
