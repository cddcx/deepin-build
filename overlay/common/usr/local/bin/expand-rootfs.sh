#!/bin/bash
# 首次启动自动扩容根分区

set -e

FLAG_FILE="/var/lib/.expanded"

if [[ -f "${FLAG_FILE}" ]]; then
    echo "Rootfs already expanded."
    exit 0
fi

echo "Expanding root filesystem..."

# 找到根分区设备
ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ -z "${ROOT_DEV}" ]]; then
    echo "ERROR: Cannot find root device"
    exit 1
fi

# 处理设备名（如 /dev/mmcblk0p1 -> /dev/mmcblk0, /dev/nvme0n1p1 -> /dev/nvme0n1）
if [[ "${ROOT_DEV}" =~ ^/dev/mmcblk[0-9]+p[0-9]+$ ]]; then
    DISK_DEV=$(echo "${ROOT_DEV}" | sed 's/p[0-9]*$//')
    PART_NUM=$(echo "${ROOT_DEV}" | sed 's/.*p//')
elif [[ "${ROOT_DEV}" =~ ^/dev/nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
    DISK_DEV=$(echo "${ROOT_DEV}" | sed 's/p[0-9]*$//')
    PART_NUM=$(echo "${ROOT_DEV}" | sed 's/.*p//')
elif [[ "${ROOT_DEV}" =~ ^/dev/sd[a-z]+[0-9]+$ ]]; then
    DISK_DEV=$(echo "${ROOT_DEV}" | sed 's/[0-9]*$//')
    PART_NUM=$(echo "${ROOT_DEV}" | sed 's/.*[^0-9]//')
else
    echo "WARNING: Unknown device pattern: ${ROOT_DEV}, skipping expansion"
    touch "${FLAG_FILE}"
    exit 0
fi

# 检查是否是 GPT 且最后一个分区
if [[ "${PART_NUM}" -ne 1 ]]; then
    echo "WARNING: Root is not the first partition, skipping expansion"
    touch "${FLAG_FILE}"
    exit 0
fi

# 扩容分区
echo "Resizing partition ${PART_NUM} on ${DISK_DEV}..."
parted "${DISK_DEV}" resizepart "${PART_NUM}" 100% || true

# 扩容文件系统
echo "Resizing filesystem..."
resize2fs "${ROOT_DEV}" || true

touch "${FLAG_FILE}"
echo "Root filesystem expanded successfully."
