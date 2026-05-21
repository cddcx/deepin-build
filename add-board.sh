#!/bin/bash
# 快速添加新板卡配置

set -e

if [[ $# -lt 2 ]]; then
    echo "用法: $0 <板卡名称> <SoC型号> [defconfig名称] [dtb名称]"
    echo "示例: $0 rock-5b rk3588 rock-5b-rk3588_defconfig rk3588-rock-5b.dtb"
    exit 1
fi

BOARD_NAME="$1"
SOC="$2"
DEFCONFIG="${3:-${BOARD_NAME}-${SOC}_defconfig}"
DTB="${4:-rk3588-${BOARD_NAME}.dtb}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_DIR="${SCRIPT_DIR}/devices/${BOARD_NAME}"

mkdir -p "${DEVICE_DIR}/overlay"

cat > "${DEVICE_DIR}/device.conf" <<EOF
# ${BOARD_NAME} 板卡配置

BOARD_NAME="${BOARD_NAME^^}"
BOARD_SOC="${SOC}"

UBOOT_DEFCONFIG="${DEFCONFIG}"
UBOOT_REPO="https://github.com/u-boot/u-boot"
UBOOT_BRANCH="v2025.07"

KERNEL_DTB="${DTB}"
KERNEL_OVERLAYS=""
KERNEL_REPO="https://github.com/armbian/linux-rockchip"
KERNEL_BRANCH="rk-6.1-rkr5.1"

DDR_BIN="rk3588_ddr_lp4_2112MHz_lp5_2736MHz_v1.16.bin"
EXTRA_PACKAGES=""
EOF

echo "板卡 ${BOARD_NAME} 配置已创建: ${DEVICE_DIR}/device.conf"
echo "请根据需要修改配置，然后运行:"
echo "  sudo BOARD=${BOARD_NAME} ./build.sh"
