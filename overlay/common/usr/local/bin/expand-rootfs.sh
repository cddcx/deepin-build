#!/bin/bash
# 首次启动扩展根分区
set -e

# 检查是否已经扩展过
if [ -f /var/lib/.expanded ]; then
    exit 0
fi

# 找到根分区设备
ROOT_PART=$(findmnt -n -o SOURCE /)
ROOT_DEV=$(lsblk -n -o PKNAME "$ROOT_PART")
PART_NUM=$(echo "$ROOT_PART" | grep -oE '[0-9]+$')

# 扩展分区
growpart "/dev/$ROOT_DEV" "$PART_NUM" 2>/dev/null || true

# 扩展文件系统
resize2fs "$ROOT_PART" 2>/dev/null || true

# 标记已扩展
touch /var/lib/.expanded
