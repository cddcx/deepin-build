#!/bin/bash
# ============================================================================
# Deepin 25 Rockchip 二次打包脚本
# 在已有 rootfs 基础上快速重建镜像
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${SCRIPT_DIR}/workspace"
OUTPUT="${SCRIPT_DIR}/output"
BOARD="${BOARD:-}"

if [[ -z "${BOARD}" ]]; then
    echo "用法: BOARD=<板卡名> $0"
    exit 1
fi

if [[ ! -d "${WORKSPACE}/rootfs" ]]; then
    echo "错误: 没有找到 rootfs，请先完整构建一次"
    exit 1
fi

source "${SCRIPT_DIR}/devices/${BOARD}/device.conf"

echo "=== 二次打包: ${BOARD_NAME} ==="

# 1. 安装 overlay
echo "[*] 安装 overlay..."
if [[ -d "${SCRIPT_DIR}/overlay/common" ]]; then
    cp -a "${SCRIPT_DIR}/overlay/common/." "${WORKSPACE}/rootfs/"
fi
if [[ -d "${SCRIPT_DIR}/devices/${BOARD}/overlay" ]]; then
    cp -a "${SCRIPT_DIR}/devices/${BOARD}/overlay/." "${WORKSPACE}/rootfs/"
fi

# 2. 生成 extlinux
echo "[*] 生成 extlinux.conf..."
kernel_version=$(ls "${WORKSPACE}/rootfs/boot"/vmlinuz-* 2>/dev/null | head -1 | sed 's/.*vmlinuz-//') || kernel_version="6.1.115"

mkdir -p "${WORKSPACE}/rootfs/boot/extlinux"
cat > "${WORKSPACE}/rootfs/boot/extlinux/extlinux.conf" <<EOF
default Deepin-SD
menu title Deepin 25 Rockchip Boot Menu
prompt 1
timeout 10

label Deepin-SD
    menu label ^Deepin 25 (SD Card)
    linux /boot/vmlinuz-${kernel_version}
    initrd /boot/initrd.img-${kernel_version}
    fdt /boot/dtb/rockchip/${KERNEL_DTB}
    append root=/dev/mmcblk1p1 rootfstype=ext4 rootwait rw rootdelay=5 console=ttyS2,1500000 console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory loglevel=3 quiet splash cma=512M

label Deepin-eMMC
    menu label ^Deepin 25 (eMMC)
    linux /boot/vmlinuz-${kernel_version}
    initrd /boot/initrd.img-${kernel_version}
    fdt /boot/dtb/rockchip/${KERNEL_DTB}
    append root=/dev/mmcblk0p1 rootfstype=ext4 rootwait rw rootdelay=5 console=ttyS2,1500000 console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory loglevel=3 quiet splash cma=512M

label Deepin-NVMe
    menu label ^Deepin 25 (NVMe)
    linux /boot/vmlinuz-${kernel_version}
    initrd /boot/initrd.img-${kernel_version}
    fdt /boot/dtb/rockchip/${KERNEL_DTB}
    append root=/dev/nvme0n1p1 rootfstype=ext4 rootwait rw rootdelay=5 console=ttyS2,1500000 console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory loglevel=3 quiet splash cma=512M

label Deepin-Recovery
    menu label ^Deepin 25 Recovery (SD)
    linux /boot/vmlinuz-${kernel_version}
    initrd /boot/initrd.img-${kernel_version}
    fdt /boot/dtb/rockchip/${KERNEL_DTB}
    append root=/dev/mmcblk1p1 rootfstype=ext4 rootwait rw console=ttyS2,1500000 console=tty1 single rescue cma=512M
EOF

# 3. 创建镜像
echo "[*] 创建镜像..."
img_file="${OUTPUT}/deepin25-${BOARD}-repack-$(date +%Y%m%d).img"
rootfs_size=$(du -sm "${WORKSPACE}/rootfs" | cut -f1)
img_size=$((rootfs_size + 512))

fallocate -l "${img_size}M" "${img_file}"
parted --script "${img_file}" mklabel gpt mkpart primary ext4 16MiB 100%

LOOP_DEV=$(losetup -f --show -P "${img_file}")
sleep 2
part_dev="${LOOP_DEV}p1"

root_uuid=$(uuidgen)
root_uuid=$(echo "${root_uuid}" | tr '[:upper:]' '[:lower:]')
mkfs.ext4 -F -U "${root_uuid}" -L root "${part_dev}"

mount_dir="${WORKSPACE}/img-mount"
mkdir -p "${mount_dir}"
mount "${part_dev}" "${mount_dir}"

rsync -aHAX --info=progress2 "${WORKSPACE}/rootfs/" "${mount_dir}/"
sync
umount "${mount_dir}"

# 烧写 U-Boot
if [[ -f "${CACHE}/u-boot/u-boot-rockchip.bin" ]]; then
    dd if="${CACHE}/u-boot/u-boot-rockchip.bin" of="${LOOP_DEV}" seek=64 bs=512 conv=fsync
fi

losetup -d "${LOOP_DEV}"
chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "${img_file}" 2>/dev/null || true

echo "=== 二次打包完成 ==="
echo "镜像: ${img_file}"
ls -lh "${img_file}"
