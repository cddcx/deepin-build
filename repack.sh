#!/bin/bash
# ============================================================================
# Deepin 25 Rockchip 镜像二次打包脚本
# 用途: 不重新编译根文件系统，仅重新打包 U-Boot/内核/DTB 到镜像
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${SCRIPT_DIR}/workspace"
OUTPUT="${SCRIPT_DIR}/output"
CACHE="${SCRIPT_DIR}/cache"
BOARD="${BOARD:-}"
DEVICE_CONFIG_DIR="${SCRIPT_DIR}/devices"

LOG_FILE="${OUTPUT}/repack-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${OUTPUT}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC}  $1" | tee -a "${LOG_FILE}"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $1" | tee -a "${LOG_FILE}"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "${LOG_FILE}"; }

cleanup() {
    if [[ -n "${LOOP_DEV:-}" ]]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

if [[ $EUID -ne 0 ]]; then
    log_error "需要 root 权限运行"
    exit 1
fi

if [[ -z "${BOARD}" ]]; then
    log_error "未指定板卡。用法: BOARD=rock-5-itx ./repack.sh"
    exit 1
fi

if [[ ! -f "${DEVICE_CONFIG_DIR}/${BOARD}/device.conf" ]]; then
    log_error "板卡 ${BOARD} 配置不存在"
    exit 1
fi

source "${DEVICE_CONFIG_DIR}/${BOARD}/device.conf"
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-${BOARD}_defconfig}"
KERNEL_DTB="${KERNEL_DTB:-${BOARD}.dtb}"
KERNEL_OVERLAYS="${KERNEL_OVERLAYS:-}"

log_info "========================================"
log_info "Deepin 25 Rockchip 镜像二次打包"
log_info "目标板卡: ${BOARD}"
log_info "========================================"

# 检查是否有 rootfs 备份
rootfs_dir="${WORKSPACE}/rootfs"
if [[ ! -f "${rootfs_dir}/bin/bash" ]]; then
    backup_files=()
    for f in "${WORKSPACE}"/rootfs-backup-*.tar.gz; do
        [[ -f "$f" ]] && backup_files+=("$f")
    done
    if [[ ${#backup_files[@]} -gt 0 ]]; then
        IFS=$'\n' sorted_backups=($(sort -V <<<"${backup_files[*]}")); unset IFS
        latest_backup="${sorted_backups[-1]}"
        log_info "解压 rootfs 备份: $(basename "${latest_backup}")"
        mkdir -p "${rootfs_dir}"
        tar xzf "${latest_backup}" -C "${rootfs_dir}"
    else
        log_error "没有可用的 rootfs 或备份，请先执行完整构建"
        exit 1
    fi
fi

# 检查内核 deb
if [[ ! -d "${CACHE}/kernel-debs" ]] || [[ $(ls -1 "${CACHE}/kernel-debs"/*.deb 2>/dev/null | wc -l) -eq 0 ]]; then
    log_error "没有缓存的内核 deb 包，请先执行完整构建"
    exit 1
fi

log_info "重新安装内核到 rootfs..."
mkdir -p "${rootfs_dir}/tmp/kernel-debs"
cp "${CACHE}/kernel-debs"/*.deb "${rootfs_dir}/tmp/kernel-debs/"

mount --bind /dev "${rootfs_dir}/dev" 2>/dev/null || true
mount -t proc proc "${rootfs_dir}/proc" 2>/dev/null || true
mount -t sysfs sysfs "${rootfs_dir}/sys" 2>/dev/null || true
cp /usr/bin/qemu-aarch64-static "${rootfs_dir}/usr/bin/" 2>/dev/null || true

chroot "${rootfs_dir}" /bin/bash -c '
    cd /tmp/kernel-debs
    dpkg -i *.deb 2>/dev/null || apt-get install -f -y
    mkdir -p /boot/dtb/rockchip/overlay
    for d in /usr/lib/linux-image-*/rockchip /boot/dtb-* /usr/lib/linux-image-*/; do
        if [[ -d "${d}" ]] && [[ -n "$(ls "${d}"/*.dtb 2>/dev/null)" ]]; then
            cp -a "${d}"/*.dtb /boot/dtb/rockchip/ 2>/dev/null || true
            if [[ -d "${d}/overlay" ]]; then
                cp -a "${d}/overlay"/*.dtbo /boot/dtb/rockchip/overlay/ 2>/dev/null || true
            fi
            break
        fi
    done
    rm -rf /tmp/kernel-debs
' || true

umount -lf "${rootfs_dir}/proc" 2>/dev/null || true
umount -lf "${rootfs_dir}/sys" 2>/dev/null || true
umount -lf "${rootfs_dir}/dev" 2>/dev/null || true

# 重新生成 extlinux.conf
log_info "重新生成 extlinux.conf..."
boot_dir="${rootfs_dir}/boot"
kernel_version=$(ls "${boot_dir}"/vmlinuz-* 2>/dev/null | head -1 | sed 's/.*vmlinuz-//') || kernel_version="6.1.115"

mkdir -p "${boot_dir}/extlinux"
dtb_path="/boot/dtb/rockchip/${KERNEL_DTB}"
overlay_path="/boot/dtb/rockchip/overlay/${KERNEL_OVERLAYS}"

cat > "${boot_dir}/extlinux/extlinux.conf" <<EOF
default Deepin-SD
menu title Deepin 25 Rockchip Boot Menu
prompt 1
timeout 10

label Deepin-SD
    menu label ^Deepin 25 (SD Card)
    linux /boot/vmlinuz-${kernel_version}
    initrd /boot/initrd.img-${kernel_version}
    fdt ${dtb_path}
    ${KERNEL_OVERLAYS:+fdtoverlays ${overlay_path}}
    append root=/dev/mmcblk1p1 rootfstype=ext4 rootwait rw rootdelay=5 console=ttyS2,1500000 console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory loglevel=3 quiet splash cma=512M drm.debug=0x1e

label Deepin-eMMC
    menu label ^Deepin 25 (eMMC)
    linux /boot/vmlinuz-${kernel_version}
    initrd /boot/initrd.img-${kernel_version}
    fdt ${dtb_path}
    ${KERNEL_OVERLAYS:+fdtoverlays ${overlay_path}}
    append root=/dev/mmcblk0p1 rootfstype=ext4 rootwait rw rootdelay=5 console=ttyS2,1500000 console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory loglevel=3 quiet splash cma=512M drm.debug=0x1e

label Deepin-NVMe
    menu label ^Deepin 25 (NVMe SSD)
    linux /boot/vmlinuz-${kernel_version}
    initrd /boot/initrd.img-${kernel_version}
    fdt ${dtb_path}
    ${KERNEL_OVERLAYS:+fdtoverlays ${overlay_path}}
    append root=/dev/nvme0n1p1 rootfstype=ext4 rootwait rw rootdelay=5 console=ttyS2,1500000 console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory loglevel=3 quiet splash cma=512M drm.debug=0x1e

label Deepin-Recovery
    menu label ^Deepin 25 Recovery (SD)
    linux /boot/vmlinuz-${kernel_version}
    initrd /boot/initrd.img-${kernel_version}
    fdt ${dtb_path}
    append root=/dev/mmcblk1p1 rootfstype=ext4 rootwait rw console=ttyS2,1500000 console=tty1 single rescue cma=512M drm.debug=0x1e
EOF

# 创建镜像
log_info "创建磁盘镜像..."
img_file="${OUTPUT}/deepin25-${BOARD}-$(date +%Y%m%d)-repack.img"
rootfs_size=$(du -sm "${rootfs_dir}" | cut -f1)
img_size=$((rootfs_size + 1024))

fallocate -l "${img_size}M" "${img_file}"
parted --script "${img_file}" mklabel gpt mkpart primary ext4 16MiB 100%

export LOOP_DEV=$(losetup -f --show -P "${img_file}")
part_dev="${LOOP_DEV}p1"
sleep 2

root_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
mkfs.ext4 -F -U "${root_uuid}" -L root "${part_dev}"

mount_dir="${WORKSPACE}/img-mount"
mkdir -p "${mount_dir}"
mount "${part_dev}" "${mount_dir}"

rsync -aHAX --info=progress2 "${rootfs_dir}/" "${mount_dir}/"
sed -i "s|UUID=.* / .*ext4|UUID=${root_uuid} / ext4|" "${mount_dir}/etc/fstab"

sync
umount "${mount_dir}"

# 烧写 U-Boot
if [[ -f "${CACHE}/u-boot/u-boot-rockchip.bin" ]]; then
    log_info "烧写 U-Boot..."
    dd if="${CACHE}/u-boot/u-boot-rockchip.bin" of="${LOOP_DEV}" seek=64 bs=512 conv=fsync status=progress
elif [[ -f "${CACHE}/u-boot/u-boot.itb" ]]; then
    dd if="${CACHE}/u-boot/u-boot.itb" of="${LOOP_DEV}" seek=64 bs=512 conv=fsync status=progress
fi

losetup -d "${LOOP_DEV}"
unset LOOP_DEV

chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "${img_file}" 2>/dev/null || true

log_info "========================================"
log_info "二次打包完成!"
log_info "输出: ${img_file}"
log_info "========================================"
