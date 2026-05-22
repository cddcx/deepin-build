#!/bin/bash
# 批量构建所有板卡镜像
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/common.sh"

# 支持的板卡列表
BOARDS=("$@")
if [ ${#BOARDS[@]} -eq 0 ]; then
    BOARDS=(rock-5-itx cm3588-nas orange-pi-5-plus quartzpro64)
fi

log_step "批量构建板卡: ${BOARDS[*]}"

FIRST=1
for board in "${BOARDS[@]}"; do
    log_step "========================================"
    log_step "构建板卡: $board"
    log_step "========================================"

    if [ "$FIRST" = "1" ]; then
        # 第一个完整构建
        sudo BOARD="$board" "${SCRIPT_DIR}/build.sh" || log_warn "板卡 $board 构建失败"
        FIRST=0
    else
        # 后续复用 rootfs
        sudo BOARD="$board" SKIP_ROOTFS=1 "${SCRIPT_DIR}/build.sh" || log_warn "板卡 $board 构建失败"
    fi
done

log_ok "所有板卡构建完成"
