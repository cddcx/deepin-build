#!/bin/bash
# ============================================================================
# 手动备份 rootfs 脚本
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${SCRIPT_DIR}/workspace"
rootfs_dir="${WORKSPACE}/rootfs"

if [[ ! -d "${rootfs_dir}" ]] || [[ ! -f "${rootfs_dir}/bin/bash" ]]; then
    echo "[ERROR] 没有找到有效的 rootfs"
    exit 1
fi

# 清理挂载
for mp in proc sys dev dev/pts dev/shm tmp var/tmp var/run run; do
    mountpoint -q "${rootfs_dir}/${mp}" 2>/dev/null && umount -lf "${rootfs_dir}/${mp}" 2>/dev/null || true
done

backup_file="${WORKSPACE}/rootfs-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
echo "[INFO] 备份 rootfs 到: ${backup_file}"

tar czf "${backup_file}" \
    --exclude='./proc' --exclude='./sys' --exclude='./dev' \
    --exclude='./tmp' --exclude='./run' --exclude='./var/run' \
    --exclude='./var/tmp' --exclude='./lost+found' \
    -C "${rootfs_dir}" . 2>/dev/null || echo "[WARN] tar 备份有警告"

if [[ -f "${backup_file}" ]]; then
    echo "[INFO] 备份完成: $(du -sh "${backup_file}" | cut -f1)"
else
    echo "[ERROR] 备份失败"
    exit 1
fi
