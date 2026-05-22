#!/bin/bash
# 二次打包脚本 - 不重新编译 rootfs，快速生成新板卡镜像
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/common.sh"

BOARD="${BOARD:?请设置 BOARD 环境变量，例如: BOARD=rock-5-itx}"
load_board_config "$BOARD"

WORKSPACE="${SCRIPT_DIR}/workspace"
ROOTFS_DIR="${WORKSPACE}/rootfs"
CACHE_DIR="${SCRIPT_DIR}/cache"
OUTPUT_DIR="${SCRIPT_DIR}/output"
KERNEL_DEBS_DIR="${CACHE_DIR}/kernel-debs"
UBOOT_DIR="${CACHE_DIR}/u-boot"

if [ ! -f "${WORKSPACE}/rootfs-backup.tar.gz" ] && [ ! -d "$ROOTFS_DIR" ]; then
    die "没有可用的 rootfs，请先执行完整构建: sudo BOARD=${BOARD} ./build.sh"
fi

# 如果没有 rootfs 但有备份，解压
if [ ! -d "$ROOTFS_DIR" ] || [ -z "$(ls -A "$ROOTFS_DIR" 2>/dev/null)" ]; then
    log_step "解压 rootfs 备份..."
    mkdir -p "$ROOTFS_DIR"
    tar -xzf "${WORKSPACE}/rootfs-backup.tar.gz" -C "$ROOTFS_DIR" --strip-components=1 || die "备份解压失败"
fi

log_step "二次打包: ${BOARD_NAME}"
log_step "跳过 rootfs 编译，直接生成镜像..."

# 重新执行 build.sh 的 Step 5-6，跳过 1-4
SKIP_ROOTFS=1 SKIP_BACKUP=1 FORCE_REBUILD_KERNEL=0 \
    bash -c "source ${SCRIPT_DIR}/build.sh" || die "二次打包失败"

log_ok "二次打包完成"
