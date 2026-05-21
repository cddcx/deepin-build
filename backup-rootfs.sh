#!/bin/bash
# ============================================================================
# Deepin 25 Rockchip Rootfs 完整备份脚本
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS_DIR="${SCRIPT_DIR}/workspace/rootfs"
OUTPUT_DIR="${1:-${SCRIPT_DIR}/workspace}"
NO_COMPRESS="${2:-}"

if [[ ! -d "${ROOTFS_DIR}" ]]; then
    echo "错误: rootfs 目录不存在: ${ROOTFS_DIR}"
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [[ "${NO_COMPRESS}" == "--no-compress" ]]; then
    BACKUP_FILE="${OUTPUT_DIR}/rootfs-backup-${TIMESTAMP}.tar"
    COMPRESS_FLAG=""
    echo "=== 开始完整备份 rootfs (无压缩) ==="
else
    BACKUP_FILE="${OUTPUT_DIR}/rootfs-backup-${TIMESTAMP}.tar.gz"
    COMPRESS_FLAG="z"
    echo "=== 开始完整备份 rootfs (gzip 压缩) ==="
fi

mkdir -p "${OUTPUT_DIR}"

echo "[*] 卸载虚拟文件系统..."
for mp in proc sys dev dev/pts dev/shm tmp var/tmp var/run run; do
    if mountpoint -q "${ROOTFS_DIR}/${mp}" 2>/dev/null; then
        echo "  卸载: ${mp}"
        sudo umount -lf "${ROOTFS_DIR}/${mp}" 2>/dev/null || true
    fi
done

echo "[*] 检查 rootfs 完整性..."
if [[ ! -f "${ROOTFS_DIR}/bin/bash" ]]; then
    echo "错误: rootfs 不完整"
    exit 1
fi

FILE_COUNT=$(find "${ROOTFS_DIR}" -type f 2>/dev/null | wc -l)
echo "[*] 发现 ${FILE_COUNT} 个文件"

echo "[*] 开始打包..."
echo "[*] 输出: ${BACKUP_FILE}"

sudo tar c${COMPRESS_FLAG}f "${BACKUP_FILE}" \
    --exclude='./proc' --exclude='./sys' --exclude='./dev' \
    --exclude='./tmp' --exclude='./run' --exclude='./var/run' \
    --exclude='./var/tmp' --exclude='./lost+found' \
    -C "${ROOTFS_DIR}" . \
    2>/dev/null || echo "[WARN] tar 备份出现警告，继续..."

if [[ -f "${BACKUP_FILE}" ]]; then
    BACKUP_SIZE=$(du -sh "${BACKUP_FILE}" | cut -f1)
    echo ""
    echo "========================================"
    echo "✓ 备份完成!"
    echo "文件: ${BACKUP_FILE}"
    echo "大小: ${BACKUP_SIZE}"
    echo "========================================"
    echo ""
    echo "二次打包使用方法:"
    echo "  sudo rm -rf workspace/rootfs"
    echo "  sudo tar xzf ${BACKUP_FILE} -C workspace/rootfs/"
    echo "  sudo BOARD=rock-5-itx ./repack.sh"
else
    echo "错误: 备份文件未生成"
    exit 1
fi
