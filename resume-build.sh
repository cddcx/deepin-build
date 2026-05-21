#!/bin/bash
# 从当前状态继续构建 Deepin 25 Rockchip 镜像
# 使用前请确保已应用固件包修复

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD="${BOARD:-rock-5-itx}"

echo "========================================"
echo "继续构建: ${BOARD}"
echo "========================================"

cd "${SCRIPT_DIR}"

# 1. 清理不完整的 rootfs（如果存在）
if [[ -d "workspace/rootfs" ]]; then
    echo "[*] 清理不完整的 rootfs..."
    sudo rm -rf workspace/rootfs
fi

# 2. 确认缓存状态
echo "[*] 检查编译缓存..."
for item in "cache/rkbin" "cache/u-boot" "cache/trusted-firmware-a" "cache/linux"; do
    if [[ -d "${item}" ]]; then
        echo "  ✓ ${item}"
    else
        echo "  ✗ ${item} 缺失"
    fi
done

# 3. 确认内核 deb 包
echo "[*] 检查内核 deb 包..."
if [[ -d "cache/kernel-debs" ]]; then
    ls -1 cache/kernel-debs/*.deb 2>/dev/null | head -5 | sed 's/^/  /'
else
    echo "  ⚠ cache/kernel-debs 不存在，内核将重新编译"
fi

# 4. 开始构建
echo "[*] 开始构建..."
sudo BOARD="${BOARD}" ./build.sh

echo "========================================"
echo "构建完成!"
echo "输出目录: ${SCRIPT_DIR}/output/"
echo "========================================"
