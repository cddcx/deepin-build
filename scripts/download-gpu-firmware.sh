#!/bin/bash
# ============================================================================
# 下载并安装 Mali G610 / Panthor GPU 固件
# 参考: https://github.com/armbian/build/tree/main/packages/blobs/rockchip
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRMWARE_DIR="${SCRIPT_DIR}/overlay/common/usr/lib/firmware"
mkdir -p "${FIRMWARE_DIR}/arm/mali"

echo "[INFO] 下载 Mali G610 GPU 固件..."

# Armbian 官方固件源
ARMBIAN_BLOB="https://github.com/armbian/build/raw/main/packages/blobs/rockchip"

# 下载顺序: 优先 g610, 回退 g610m, 再回退 mali
firmware_files=(
    "mali_csffw_g610.bin"
    "mali_csffw.bin"
)

for fw in "${firmware_files[@]}"; do
    url="${ARMBIAN_BLOB}/${fw}"
    dest="${FIRMWARE_DIR}/arm/mali/${fw}"
    if [[ ! -f "${dest}" ]]; then
        echo "[INFO] 下载 ${fw}..."
        curl -sL "${url}" -o "${dest}" 2>/dev/null || true
        if [[ -f "${dest}" ]] && [[ $(stat -c%s "${dest}" 2>/dev/null) -gt 100 ]]; then
            echo "[OK] ${fw} 下载完成 ($(stat -c%s "${dest}" | numfmt --to=iec))"
        else
            rm -f "${dest}"
            echo "[WARN] ${fw} 下载失败"
        fi
    else
        echo "[OK] ${fw} 已存在"
    fi
done

# 创建符号链接（Panthor 驱动查找 mali_csffw.bin）
cd "${FIRMWARE_DIR}/arm/mali"
if [[ -f "mali_csffw_g610.bin" ]] && [[ ! -f "mali_csffw.bin" ]]; then
    ln -sf mali_csffw_g610.bin mali_csffw.bin
    echo "[OK] 创建符号链接: mali_csffw.bin -> mali_csffw_g610.bin"
fi

echo "[INFO] GPU 固件准备完成"
ls -la "${FIRMWARE_DIR}/arm/mali/"
