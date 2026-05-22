#!/bin/bash
# ============================================================================
# 批量构建所有板卡的 Deepin 25 Rockchip 镜像
# 用法: ./build-all.sh [board1 board2 ...]
# 不带参数则构建所有支持的板卡
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_CONFIG_DIR="${SCRIPT_DIR}/devices"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC}  $1"; }

# 获取所有板卡列表
get_all_boards() {
    ls -1 "${DEVICE_CONFIG_DIR}" | while read d; do
        if [[ -f "${DEVICE_CONFIG_DIR}/${d}/device.conf" ]]; then
            echo "${d}"
        fi
    done
}

# 要构建的板卡
if [[ $# -gt 0 ]]; then
    BOARDS=("$@")
else
    mapfile -t BOARDS < <(get_all_boards)
fi

if [[ ${#BOARDS[@]} -eq 0 ]]; then
    log_error "没有找到任何板卡配置"
    exit 1
fi

log_info "========================================"
log_info "批量构建 Deepin 25 Rockchip 镜像"
log_info "板卡列表: ${BOARDS[*]}"
log_info "========================================"

# 先构建第一个板卡的完整 rootfs（包括内核/U-Boot）
FIRST_BOARD="${BOARDS[0]}"
log_step "第一步: 构建 ${FIRST_BOARD} (完整构建，包含 rootfs)"
sudo BOARD="${FIRST_BOARD}" "${SCRIPT_DIR}/build.sh"

# 备份 rootfs 供后续板卡复用
log_step "备份 rootfs 供后续板卡复用..."
"${SCRIPT_DIR}/backup-rootfs.sh" 2>/dev/null || true

# 构建剩余板卡（复用 rootfs，只重新编译 U-Boot/内核/DTB）
for board in "${BOARDS[@]:1}"; do
    log_step "构建 ${board} (复用 rootfs)..."
    sudo rm -rf "${SCRIPT_DIR}/workspace/rootfs"
    sudo BOARD="${board}" "${SCRIPT_DIR}/build.sh"
done

log_info "========================================"
log_info "所有板卡构建完成!"
log_info "输出目录: ${SCRIPT_DIR}/output"
log_info "========================================"
ls -lh "${SCRIPT_DIR}/output"/deepin25-*.img 2>/dev/null || true
