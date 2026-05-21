#!/bin/bash
# 首次启动自动扩容根分区
set -e

FLAG_FILE="/var/lib/.expanded"
[[ -f "$FLAG_FILE" ]] && exit 0

echo "[expand-rootfs] 正在扩容根分区..."

# 获取根设备
ROOT_DEV=$(findmnt -n -o SOURCE /)
ROOT_DISK=$(lsblk -n -o PKNAME "$ROOT_DEV")
PART_NUM=$(echo "$ROOT_DEV" | grep -oE '[0-9]+$')

if [[ -z "$ROOT_DISK" ]]; then
    echo "[expand-rootfs] 无法确定磁盘设备，跳过"
    exit 0
fi

# 扩容分区
growpart "/dev/${ROOT_DISK}" "$PART_NUM" || true

# 扩容文件系统
resize2fs "$ROOT_DEV" || true

# 标记已完成
touch "$FLAG_FILE"
echo "[expand-rootfs] 扩容完成"
