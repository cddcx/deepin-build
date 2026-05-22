#!/bin/bash
# 手动备份 rootfs
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/common.sh"

WORKSPACE="${SCRIPT_DIR}/workspace"
ROOTFS_DIR="${WORKSPACE}/rootfs"

if [ ! -d "$ROOTFS_DIR" ]; then
    die "rootfs 目录不存在"
fi

log_step "备份 rootfs..."
tar -czf "${WORKSPACE}/rootfs-backup-$(date +%Y%m%d-%H%M%S).tar.gz" -C "$ROOTFS_DIR" . || die "备份失败"
log_ok "备份完成"
