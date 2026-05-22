#!/bin/bash
# ============================================================================
# Deepin 25 Rockchip 通用多板卡镜像构建系统 v2.0
# 整合参考:
#   - https://github.com/xiaobao1980/deepin-build
#   - https://github.com/YukariChiba/deepin-ports-image
#   - https://github.com/deepin-community/deepin-ports-kernel
#   - https://github.com/xiaobao1980/armbian-build (board/family 配置)
#   - https://www.deepin.org/zh/deepin25-orangepi/
#
# 特性:
#   - 多板卡支持: rock-5-itx, cm3588-nas, orange-pi-5-plus, quartzpro64...
#   - 多介质启动: SD / NVMe / eMMC (U-Boot 启动顺序 + extlinux 菜单)
#   - 调用 armbian-build 内核/uboot 配置作为参考源
#   - 智能 rootfs 管理: 同板卡复用 / 跨板卡备份 / 全新构建
#   - 二次打包: 无需重新编译根文件系统
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${SCRIPT_DIR}/workspace"
OUTPUT="${SCRIPT_DIR}/output"
CACHE="${SCRIPT_DIR}/cache"
BOARD="${BOARD:-}"
DEVICE_CONFIG_DIR="${SCRIPT_DIR}/devices"

DIST_NAME="deepin"
DIST_VERSION="crimson"
ARCH="arm64"
IMAGE_SIZE_MB="8192"

LOG_FILE="${OUTPUT}/build-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${WORKSPACE}" "${OUTPUT}" "${CACHE}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC}  $1" | tee -a "${LOG_FILE}"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $1" | tee -a "${LOG_FILE}"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "${LOG_FILE}"; }
log_step() { echo -e "${BLUE}[STEP]${NC}  $1" | tee -a "${LOG_FILE}"; }

cleanup() {
    log_warn "执行清理..."
    for mp in proc sys dev dev/pts dev/shm tmp var/tmp var/run run; do
        if mountpoint -q "${WORKSPACE}/rootfs/${mp}" 2>/dev/null; then
            umount -lf "${WORKSPACE}/rootfs/${mp}" 2>/dev/null || true
        fi
    done
    if [[ -d "${WORKSPACE}/rootfs" ]]; then
        local cleanup_mnts
        cleanup_mnts=$(cat /proc/mounts | grep "${WORKSPACE}/rootfs" | awk '{print $2}' | sort -r || true)
        if [[ -n "${cleanup_mnts}" ]]; then
            echo "${cleanup_mnts}" | while read mnt; do umount -lf "$mnt" 2>/dev/null || true; done
        fi
    fi
    if [[ -n "${LOOP_DEV:-}" ]]; then
        kpartx -d "${LOOP_DEV}" 2>/dev/null || true
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
    rm -f "${WORKSPACE}"/*.tmp 2>/dev/null || true
}
trap cleanup EXIT INT TERM

check_prerequisites() {
    log_step "检查构建依赖..."
    # 可执行命令检测
    local deps=(mmdebstrap qemu-aarch64-static systemd-nspawn parted kpartx mkfs.ext4 mkfs.fat losetup fallocate gpg curl git rsync bc)
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then missing+=("$dep"); fi
    done
    # 库包/头文件检测（不是可执行命令）
    if ! python3 -c "import setuptools" &>/dev/null; then
        missing+=("python3-setuptools")
    fi
    if [[ ! -f "/usr/include/python3.12/Python.h" ]] && [[ ! -f "/usr/include/python3.11/Python.h" ]] && [[ ! -f "/usr/include/python3.10/Python.h" ]]; then
        missing+=("python3-dev")
    fi
    if [[ ! -f "/usr/include/gnutls/gnutls.h" ]]; then
        missing+=("libgnutls28-dev")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "缺少依赖: ${missing[*]}"
        log_info "安装命令:"
        log_info "  sudo apt install -y mmdebstrap qemu-user-static systemd-container binfmt-support \\"
        log_info "    parted kpartx dosfstools e2fsprogs rsync git curl gpg \\"
        log_info "    build-essential crossbuild-essential-arm64 libncurses-dev \\"
        log_info "    swig flex bison u-boot-tools bc libssh-dev kmod cpio \\"
        log_info "    libelf-dev libssl-dev dwarves python3-pyelftools"
        exit 1
    fi
    if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
        log_warn "qemu-aarch64 binfmt 未注册，尝试注册..."
        systemctl restart systemd-binfmt 2>/dev/null || update-binfmts --enable qemu-aarch64 2>/dev/null || true
    fi
    if [[ $EUID -ne 0 ]]; then
        log_error "需要 root 权限运行"
        exit 1
    fi
    if [[ -z "${BOARD}" ]]; then
        log_error "未指定板卡。用法: BOARD=rock-5-itx ./build.sh"
        log_info "可用板卡:"
        ls -1 "${DEVICE_CONFIG_DIR}" 2>/dev/null || true
        exit 1
    fi
    if [[ ! -f "${DEVICE_CONFIG_DIR}/${BOARD}/device.conf" ]]; then
        log_error "板卡 ${BOARD} 配置不存在: ${DEVICE_CONFIG_DIR}/${BOARD}/device.conf"
        exit 1
    fi
    log_info "目标板卡: ${BOARD}"
    log_info "所有依赖检查通过"
}

load_device_config() {
    log_step "加载板卡配置: ${BOARD}"
    source "${DEVICE_CONFIG_DIR}/${BOARD}/device.conf"

    # 默认值
    UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-${BOARD}_defconfig}"
    KERNEL_DTB="${KERNEL_DTB:-${BOARD}.dtb}"
    KERNEL_OVERLAYS="${KERNEL_OVERLAYS:-}"
    DDR_BIN="${DDR_BIN:-}"

    # 从 armbian-build 参考配置读取（如果存在）
    local armbian_board_conf="${SCRIPT_DIR}/armbian-board-ref/${BOARD}.conf"
    if [[ -f "${armbian_board_conf}" ]]; then
        log_info "发现 Armbian 参考配置，提取关键参数..."
        # 提取 BOOTCONFIG, BOOT_FDT_FILE, KERNEL_TARGET 等作为参考
        grep -E "^(BOOTCONFIG|BOOT_FDT_FILE|KERNEL_TARGET|SERIALCON|DEFAULT_OVERLAYS)=" "${armbian_board_conf}" 2>/dev/null | while read line; do
            log_info "  Armbian ref: ${line}"
        done || true
    fi

    log_info "U-Boot defconfig: ${UBOOT_DEFCONFIG}"
    log_info "Kernel DTB: ${KERNEL_DTB}"
    log_info "Kernel Overlays: ${KERNEL_OVERLAYS:-无}"
    log_info "SOC: ${BOARD_SOC:-rk3588}"
}

prepare_sources() {
    log_step "准备源码和固件..."
    mkdir -p "${CACHE}"

    # rkbin - Rockchip 官方固件二进制
    if [[ ! -d "${CACHE}/rkbin" ]]; then
        log_info "下载 rkbin..."
        git clone --depth=1 https://github.com/armbian/rkbin "${CACHE}/rkbin"
    else
        log_info "更新 rkbin..."
        (cd "${CACHE}/rkbin" && git pull --ff-only) || true
    fi

    # U-Boot - 优先使用板卡指定的源，否则主线
    if [[ ! -d "${CACHE}/u-boot" ]]; then
        log_info "下载 U-Boot..."
        local uboot_repo="${UBOOT_REPO:-https://github.com/u-boot/u-boot}"
        local uboot_branch="${UBOOT_BRANCH:-v2025.07}"
        if ! git clone --depth=1 -b "${uboot_branch}" "${uboot_repo}" "${CACHE}/u-boot" 2>/tmp/git-uboot-err.log; then
            log_warn "分支 ${uboot_branch} 克隆失败，回退到主线 v2025.07..."
            rm -rf "${CACHE}/u-boot"
            git clone --depth=1 -b v2025.07 https://github.com/u-boot/u-boot "${CACHE}/u-boot"
        fi
    fi

    # TF-A (BL31)
    if [[ ! -d "${CACHE}/trusted-firmware-a" ]]; then
        log_info "下载 TF-A..."
        git clone --depth=1 -b v2.13.0 https://github.com/TrustedFirmware-A/trusted-firmware-a "${CACHE}/trusted-firmware-a"
    fi

    # 内核 - 优先使用板卡指定的源
    local kernel_repo="${KERNEL_REPO:-https://github.com/armbian/linux-rockchip}"
    local kernel_branch="${KERNEL_BRANCH:-rk-6.1-rkr5.1}"

    if [[ ! -f "${CACHE}/linux-rockchip/Makefile" ]]; then
        log_info "下载内核源码 (${kernel_branch})..."
        rm -rf "${CACHE}/linux-rockchip"
        git clone --depth=1 -b "${kernel_branch}" "${kernel_repo}" "${CACHE}/linux-rockchip"
    fi

    # 下载 Armbian board/family 参考配置（用于提取启动顺序、补丁等）
    if [[ ! -d "${SCRIPT_DIR}/armbian-board-ref" ]]; then
        log_info "下载 Armbian 参考配置..."
        mkdir -p "${SCRIPT_DIR}/armbian-board-ref"
        # 仅下载关键配置文件
        local armbian_raw="https://raw.githubusercontent.com/xiaobao1980/armbian-build/main"
        for f in "config/boards/${BOARD}.conf" "config/sources/families/${BOARD_FAMILY:-rockchip-rk3588}.conf" "config/sources/families/include/rockchip64_common.inc"; do
            curl -sL "${armbian_raw}/${f}" -o "${SCRIPT_DIR}/armbian-board-ref/$(basename ${f})" 2>/dev/null || true
        done
    fi

    # 下载 GPU 固件
    if [[ ! -f "${SCRIPT_DIR}/overlay/common/usr/lib/firmware/arm/mali/mali_csffw.bin" ]]; then
        log_info "下载 GPU 固件..."
        "${SCRIPT_DIR}/scripts/download-gpu-firmware.sh" 2>/dev/null || true
    fi

    log_info "源码准备完成"
}

build_tfa() {
    log_step "编译 TF-A (BL31)..."
    pushd "${CACHE}/trusted-firmware-a"
    make clean || true
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make PLAT=rk3588 bl31 -j$(nproc)
    export BL31="${PWD}/build/rk3588/release/bl31/bl31.elf"
    if [[ ! -f "${BL31}" ]]; then log_error "TF-A 编译失败"; exit 1; fi
    log_info "TF-A 编译完成: ${BL31}"
    popd
}

build_uboot() {
    log_step "编译 U-Boot..."

    # 确保 python3-setuptools 已安装（U-Boot 的 pylibfdt 需要）
    if ! python3 -c "import setuptools" 2>/dev/null; then
        log_warn "缺少 python3-setuptools，正在安装..."
        apt-get install -y python3-setuptools 2>/dev/null ||             apt-get install -y python3-distutils 2>/dev/null || true
    fi

    pushd "${CACHE}/u-boot"
    make clean || true

    # DDR 固件自动搜索
    local ddr_file=""
    local search_paths=("${CACHE}/rkbin/rk35" "${CACHE}/rkbin/bin/rk35" "${CACHE}/rkbin")
    for sp in "${search_paths[@]}"; do
        if [[ -d "${sp}" ]]; then
            local candidates=()
            for f in "${sp}"/rk3588_ddr_*.bin; do [[ -f "$f" ]] && candidates+=("$f"); done
            if [[ ${#candidates[@]} -gt 0 ]]; then
                IFS=$'\n' sorted=($(sort -V <<<"${candidates[*]}")); unset IFS
                ddr_file="${sorted[-1]}"; break
            fi
        fi
    done
    if [[ -z "${ddr_file}" ]]; then
        ddr_file=$(find "${CACHE}/rkbin" -name "rk3588_ddr_*.bin" -type f 2>/dev/null | sort -V | tail -1) || true
    fi
    if [[ -z "${ddr_file}" || ! -f "${ddr_file}" ]]; then
        log_error "找不到 RK3588 DDR 固件"
        exit 1
    fi
    export ROCKCHIP_TPL="${ddr_file}"
    log_info "使用 DDR 固件: $(basename "${ROCKCHIP_TPL}")"

    export BL31="${CACHE}/trusted-firmware-a/build/rk3588/release/bl31/bl31.elf"

    # defconfig 回退策略
    local defconfig="${UBOOT_DEFCONFIG}"
    if [[ ! -f "configs/${defconfig}" ]]; then
        log_warn "defconfig ${defconfig} 不存在，尝试回退..."
        local fallback_defs=("rock-5-itx-rk3588_defconfig" "rock5-rk3588_defconfig" "rock5b-rk3588_defconfig" "rock-5a-rk3588_defconfig")
        for fb in "${fallback_defs[@]}"; do
            if [[ -f "configs/${fb}" ]]; then 
                defconfig="${fb}"; 
                log_warn "使用回退 defconfig: ${defconfig}"; 
                break; 
            fi
        done
    fi
    if [[ ! -f "configs/${defconfig}" ]]; then 
        log_error "找不到任何可用的 U-Boot defconfig"; 
        exit 1; 
    fi

    # 应用 Armbian 参考的启动顺序补丁（如果存在）
    if [[ -f "${SCRIPT_DIR}/armbian-board-ref/${BOARD}.conf" ]]; then
        local boot_order_patch=$(grep -A20 "rockchip_uboot_targets" "${SCRIPT_DIR}/armbian-board-ref/${BOARD}.conf" 2>/dev/null | head -1)
        if [[ -n "${boot_order_patch}" ]]; then
            log_info "检测到 Armbian 启动顺序配置，应用补丁..."
            # SD -> mmc1, NVMe -> nvme, eMMC -> mmc0
            sed -i 's/#define BOOT_TARGETS.*/#define BOOT_TARGETS "mmc1 nvme mmc0 scsi usb pxe dhcp spi"/' include/configs/rockchip-common.h 2>/dev/null || true
        fi
    fi

    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make "${defconfig}"
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make -j$(nproc)

    if [[ -f "u-boot-rockchip.bin" ]]; then 
        export UBOOT_BIN="${PWD}/u-boot-rockchip.bin"
    elif [[ -f "u-boot.itb" ]]; then 
        export UBOOT_BIN="${PWD}/u-boot.itb"
    else 
        log_error "U-Boot 编译输出未找到"; exit 1
    fi
    log_info "U-Boot 编译完成: ${UBOOT_BIN}"
    popd
}

build_kernel() {
    # 检查缓存的内核 deb
    if [[ -d "${CACHE}/kernel-debs" ]]; then
        local deb_count
        deb_count=$(ls -1 "${CACHE}/kernel-debs"/*.deb 2>/dev/null | wc -l)
        if [[ ${deb_count} -gt 0 ]]; then
            log_info "使用已编译内核 deb 包 (${deb_count} 个)，跳过编译"
            export KERNEL_DEB_DIR="${CACHE}/kernel-debs"
            return 0
        fi
    fi

    log_step "编译内核..."
    if [[ ! -f "${CACHE}/linux-rockchip/Makefile" ]]; then
        log_warn "内核源码缺失，重新下载..."
        rm -rf "${CACHE}/linux-rockchip"
        local kernel_repo="${KERNEL_REPO:-https://github.com/armbian/linux-rockchip}"
        local kernel_branch="${KERNEL_BRANCH:-rk-6.1-rkr5.1}"
        git clone --depth=1 -b "${kernel_branch}" "${kernel_repo}" "${CACHE}/linux-rockchip"
    fi
    pushd "${CACHE}/linux-rockchip"

    make clean || true

    # defconfig 检测
    local defconfigs=("rockchip_linux_defconfig" "rockchip_defconfig")
    local found=""
    for dc in "${defconfigs[@]}"; do
        if [[ -f "arch/arm64/configs/${dc}" ]]; then found="${dc}"; break; fi
    done
    if [[ -z "${found}" ]]; then 
        log_error "找不到内核 defconfig"; exit 1; 
    fi
    log_info "使用内核 defconfig: ${found}"

    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make "${found}"
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make bindeb-pkg -j$(nproc)

    mkdir -p "${CACHE}/kernel-debs"
    mv ../*.deb "${CACHE}/kernel-debs/" 2>/dev/null || true

    # 清理旧版本，保留最新
    local deb_dir="${CACHE}/kernel-debs"
    local all_debs
    all_debs=$(ls -1 "${deb_dir}"/*.deb 2>/dev/null | sort -V)
    if [[ -n "${all_debs}" ]]; then
        declare -A latest_deb
        for deb in ${all_debs}; do
            local basename_pkg
            basename_pkg=$(basename "${deb}" | sed 's/_[^_]*_arm64\.deb$//')
            latest_deb["${basename_pkg}"]="${deb}"
        done
        for deb in ${all_debs}; do
            basename_pkg=$(basename "${deb}" | sed 's/_[^_]*_arm64\.deb$//')
            if [[ "${deb}" != "${latest_deb[${basename_pkg}]}" ]]; then
                rm -f "${deb}"
            fi
        done
    fi

    # 清理 cache/ 根目录残留
    for f in "${CACHE}"/linux-*.deb "${CACHE}"/linux-image-*.deb "${CACHE}"/linux-headers-*.deb "${CACHE}"/linux-libc-dev-*.deb; do
        [[ -f "$f" ]] && rm -f "$f"
    done

    log_info "保留的内核 deb:"
    ls -1 "${deb_dir}"/*.deb 2>/dev/null | sed 's/^/  /' || true
    export KERNEL_DEB_DIR="${deb_dir}"
    popd
}

build_rootfs() {
    log_step "构建根文件系统..."
    local rootfs_dir="${WORKSPACE}/rootfs"

    # === 智能 rootfs 管理 ===
    if [[ -z "${SKIP_ROOTFS:-}" ]]; then
        # 1. 已有完整 rootfs → 直接使用（同板卡增量构建）
        if [[ -f "${rootfs_dir}/bin/bash" && -d "${rootfs_dir}/boot" ]]; then
            log_info "发现已有完整 rootfs，直接使用（同板卡增量构建）"
            log_info "如需重新构建: SKIP_ROOTFS=1 BOARD=${BOARD} ./build.sh"
            export CHROOT_EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
            return 0
        fi

        # 2. 无 rootfs 但有备份 → 解压备份（跨板卡复用）
        local backup_files=()
        for f in "${WORKSPACE}"/rootfs-backup-*.tar.gz; do
            [[ -f "$f" ]] && backup_files+=("$f")
        done

        if [[ ${#backup_files[@]} -gt 0 ]]; then
            IFS=$'\n' sorted_backups=($(sort -V <<<"${backup_files[*]}")); unset IFS
            local latest_backup="${sorted_backups[-1]}"
            log_info "发现 rootfs 备份: $(basename "${latest_backup}")"
            log_info "解压备份用于构建..."

            if [[ -d "${rootfs_dir}" ]]; then
                for mp in proc sys dev dev/pts dev/shm tmp var/tmp var/run run; do
                    mountpoint -q "${rootfs_dir}/${mp}" 2>/dev/null && umount -lf "${rootfs_dir}/${mp}" 2>/dev/null || true
                done
                rm -rf "${rootfs_dir}"
            fi
            mkdir -p "${rootfs_dir}"
            tar xzf "${latest_backup}" -C "${rootfs_dir}" 2>/dev/null || { log_error "备份解压失败"; exit 1; }

            if [[ ! -f "${rootfs_dir}/bin/bash" ]]; then log_error "备份解压后不完整"; exit 1; fi
            local file_count; file_count=$(find "${rootfs_dir}" -type f 2>/dev/null | wc -l)
            log_info "备份解压完成: ${file_count} 个文件"
            export CHROOT_EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
            return 0
        fi
    fi

    # === 全新构建 ===
    if [[ -d "${rootfs_dir}" ]]; then
        log_warn "发现已有 rootfs，准备完整备份..."
        for mp in proc sys dev dev/pts dev/shm tmp var/tmp var/run run; do
            mountpoint -q "${rootfs_dir}/${mp}" 2>/dev/null && umount -lf "${rootfs_dir}/${mp}" 2>/dev/null || true
        done
        local residual_mnts
        residual_mnts=$(cat /proc/mounts | grep "${rootfs_dir}" | awk '{print $2}' | sort -r || true)
        if [[ -n "${residual_mnts}" ]]; then
            echo "${residual_mnts}" | while read mnt; do umount -lf "$mnt" 2>/dev/null || true; done
        fi

        local backup_file="${WORKSPACE}/rootfs-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        log_info "备份到: ${backup_file}"
        tar czf "${backup_file}" \
            --exclude='./proc' --exclude='./sys' --exclude='./dev' \
            --exclude='./tmp' --exclude='./run' --exclude='./var/run' \
            --exclude='./var/tmp' --exclude='./lost+found' \
            -C "${rootfs_dir}" . 2>/dev/null || log_warn "tar 备份警告，继续..."
        if [[ -f "${backup_file}" ]]; then
            log_info "备份完成: $(du -sh "${backup_file}" | cut -f1)"
        fi
        rm -rf "${rootfs_dir}"
    fi

    mkdir -p "${rootfs_dir}"

    # 最小基础包集（容错，不强制 firmware-realtek 等可能缺失的包）
    local base_packages="ca-certificates,locales,sudo,apt,adduser,polkitd,systemd,network-manager,dbus-daemon,apt-utils,bash-completion,curl,vim,bash,deepin-keyring,init,ssh,net-tools,iputils-ping,lshw,iproute2,iptables,procps,wpasupplicant,fdisk,initramfs-tools,pciutils,usbutils"
    export CHROOT_EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
    local repos="deb https://community-packages.deepin.com/beige/ crimson main commercial community"

    # 导入 Deepin GPG 密钥
    if [[ ! -f /usr/share/keyrings/deepin-archive-crimson-keyring.gpg ]]; then
        log_info "导入 Deepin GPG 密钥..."
        gpg --keyserver keyserver.ubuntu.com --recv-keys 425956BB3E31DF51 2>/dev/null || \
            gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 425956BB3E31DF51 2>/dev/null || true
        gpg --export 425956BB3E31DF51 2>/dev/null | tee /usr/share/keyrings/deepin-archive-crimson-keyring.gpg >/dev/null || true
    fi

    log_info "开始 mmdebstrap (这可能需要 10-30 分钟)..."
    mmdebstrap \
        --hook-dir=/usr/share/mmdebstrap/hooks/merged-usr \
        --skip=check/empty \
        --include="${base_packages}" \
        --components="main,commercial,community" \
        --variant=minbase \
        --architectures="${ARCH}" \
        --keyring=/usr/share/keyrings/deepin-archive-crimson-keyring.gpg \
        "${DIST_VERSION}" \
        "${rootfs_dir}" \
        "${repos}" \
        2>&1 | tee -a "${LOG_FILE}"

    if [[ ! -f "${rootfs_dir}/bin/bash" ]]; then log_error "根文件系统构建失败"; exit 1; fi
    log_info "根文件系统构建完成"
}

configure_rootfs() {
    log_step "配置根文件系统 (chroot)..."
    local rootfs_dir="${WORKSPACE}/rootfs"

    mount --bind /dev "${rootfs_dir}/dev"
    mount -t proc proc "${rootfs_dir}/proc"
    mount -t sysfs sysfs "${rootfs_dir}/sys"
    mount -t tmpfs -o "size=99%" tmpfs "${rootfs_dir}/tmp"
    cp /usr/bin/qemu-aarch64-static "${rootfs_dir}/usr/bin/" 2>/dev/null || true

    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=C

    chroot "${rootfs_dir}" /bin/bash <<'CHROOT_EOF'
set -e

# 配置 locales
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen 2>/dev/null || true
dpkg-reconfigure -f noninteractive locales 2>/dev/null || true

# 配置时区
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 设置主机名
echo "deepin-rockchip" > /etc/hostname
cat > /etc/hosts <<'HOSTS'
127.0.0.1 localhost
127.0.1.1 deepin-rockchip
HOSTS

# 配置网络
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable systemd-resolved 2>/dev/null || true
apt-get install -y resolvconf 2>/dev/null || true

# 创建用户
useradd -m -G users,sudo,audio,video,netdev,input -s /bin/bash deepin 2>/dev/null || true
echo "deepin:deepin" | chpasswd
echo "root:root" | chpasswd

# 配置 sudo
mkdir -p /etc/sudoers.d
echo "deepin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deepin
chmod 440 /etc/sudoers.d/deepin

# 配置 APT 源
cat > /etc/apt/sources.list <<'APTSOURCES'
# Deepin 25 社区稳定源
deb https://community-packages.deepin.com/beige/ crimson main commercial community
# HWE 硬件支持源
deb https://community-packages.deepin.com/hwe-25/ unstable main community commercial
APTSOURCES

mkdir -p /etc/apt/sources.list.d
cat > /etc/apt/sources.list.d/appstore.list <<'EOF'
deb https://com-store-packages.uniontech.com/appstore-V25 crimson appstore
EOF

# 更新 apt
apt-get update 2>&1 | tee /tmp/apt-update.log || true
if grep -q "404" /tmp/apt-update.log 2>/dev/null; then
    echo "[WARN] 部分源 404，禁用问题源..."
    for bad_repo in $(grep "404" /tmp/apt-update.log | grep -oP "https?://[^ ]+" | sort -u); do
        find /etc/apt/sources.list.d/ -type f -exec sed -i "s|deb ${bad_repo}|# deb ${bad_repo}|g" {} \;
    done
    apt-get update 2>/dev/null || true
fi

# 安装板卡额外包（容错，逐个安装）
if [[ -n "${CHROOT_EXTRA_PACKAGES:-}" ]]; then
    echo "[chroot] 安装额外包: ${CHROOT_EXTRA_PACKAGES}"
    for pkg in ${CHROOT_EXTRA_PACKAGES//,/ }; do
        apt-get install -y "${pkg}" 2>/dev/null || echo "[WARN] ${pkg} 安装失败，跳过"
    done
fi

# 安装可选系统包
for pkg in ntpsec-ntpdate fake-hwclock cloud-guest-utils dmidecode; do
    apt-get install -y "${pkg}" 2>/dev/null || echo "[WARN] ${pkg} 不可用，跳过"
done

# 安装桌面环境（容错）
apt-get install -y \
    deepin-desktop-environment-core \
    deepin-desktop-environment-base \
    deepin-desktop-environment-cli \
    deepin-desktop-environment-extras \
    firefox ddm treeland 2>/dev/null || true

# 配置显示管理器
systemctl disable lightdm 2>/dev/null || true
systemctl enable ddm 2>/dev/null || true
getent group video >/dev/null || groupadd -r video
getent group render >/dev/null || groupadd -r render
usermod -a -G video,render,audio,input deepin 2>/dev/null || true

# 安装 Rockchip 多媒体包（容错）
for pkg in librockchip-mpp1 librockchip-vpu0 gstreamer1.0-rockchip1 rga2 rockchip-mpp-drm; do
    apt-get install -y "${pkg}" 2>/dev/null || echo "[WARN] ${pkg} 不可用，跳过"
done

# 启用 first-boot 扩容
if [[ -f /etc/systemd/system/expand-rootfs.service ]]; then
    systemctl enable expand-rootfs.service 2>/dev/null || true
fi

# 确保 initramfs 包含存储驱动（SD/eMMC/NVMe）
cat >> /etc/initramfs-tools/modules <<'INITMOD'
# Rockchip 存储驱动
rockchip_pcie
phy_rockchip_pcie
nvme
nvme_core
mmc_block
sdhci_of_arasan
sdhci_pltfm
sdhci
dw_mmc
dw_mmc_rockchip
rkwifi
INITMOD
update-initramfs -u -k all 2>/dev/null || true

# 清理
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*
CHROOT_EOF

    umount -lf "${rootfs_dir}/tmp" 2>/dev/null || true
    umount -lf "${rootfs_dir}/proc" 2>/dev/null || true
    umount -lf "${rootfs_dir}/sys" 2>/dev/null || true
    umount -lf "${rootfs_dir}/dev" 2>/dev/null || true

    log_info "根文件系统配置完成"
}

install_overlays() {
    log_step "安装 overlay 文件..."
    local rootfs_dir="${WORKSPACE}/rootfs"
    local common_overlay="${SCRIPT_DIR}/overlay/common"
    local board_overlay="${DEVICE_CONFIG_DIR}/${BOARD}/overlay"

    # 使用 rsync 代替 cp -a，-K 保持符号链接（避免 merged-usr 的 lib -> usr/lib 被覆盖）
    if [[ -d "${common_overlay}" ]]; then
        log_info "复制通用 overlay..."
        rsync -aK --ignore-errors "${common_overlay}/" "${rootfs_dir}/" 2>/dev/null ||             cp -a --parents "${common_overlay}/." "${rootfs_dir}/" 2>/dev/null || true
    fi
    if [[ -d "${board_overlay}" ]]; then
        log_info "复制板卡 overlay..."
        rsync -aK --ignore-errors "${board_overlay}/" "${rootfs_dir}/" 2>/dev/null ||             cp -a --parents "${board_overlay}/." "${rootfs_dir}/" 2>/dev/null || true
    fi

    # 复制内核 deb 到 chroot
    if [[ -d "${KERNEL_DEB_DIR}" ]]; then
        local deb_count
        deb_count=$(ls -1 "${KERNEL_DEB_DIR}"/*.deb 2>/dev/null | wc -l)
        if [[ ${deb_count} -gt 0 ]]; then
            mkdir -p "${rootfs_dir}/tmp/kernel-debs"
            cp "${KERNEL_DEB_DIR}"/*.deb "${rootfs_dir}/tmp/kernel-debs/"
            log_info "已复制 ${deb_count} 个内核 deb 包到 chroot"
        fi
    fi

    log_info "Overlay 安装完成"
}

install_kernel() {
    log_step "安装内核到根文件系统..."
    local rootfs_dir="${WORKSPACE}/rootfs"

    if [[ ! -d "${KERNEL_DEB_DIR}" ]] || [[ $(ls -1 "${KERNEL_DEB_DIR}"/*.deb 2>/dev/null | wc -l) -eq 0 ]]; then
        log_warn "没有缓存的内核 deb 包"
        return 0
    fi

    mount --bind /dev "${rootfs_dir}/dev"
    mount -t proc proc "${rootfs_dir}/proc"
    mount -t sysfs sysfs "${rootfs_dir}/sys"
    mount -t tmpfs -o "size=99%" tmpfs "${rootfs_dir}/tmp"
    cp /usr/bin/qemu-aarch64-static "${rootfs_dir}/usr/bin/" 2>/dev/null || true

    # 在 mount tmpfs 之后复制 deb 包到挂载点内（避免 tmpfs mount 覆盖）
    mkdir -p "${rootfs_dir}/tmp/kernel-debs"
    cp "${KERNEL_DEB_DIR}"/*.deb "${rootfs_dir}/tmp/kernel-debs/"
    log_info "已复制 $(ls -1 "${rootfs_dir}/tmp/kernel-debs"/*.deb | wc -l) 个内核 deb 包到 chroot"

    chroot "${rootfs_dir}" /bin/bash <<'CHROOT_EOF'
set -e
cd /tmp/kernel-debs
# 安装内核包
dpkg -i *.deb 2>/dev/null || apt-get install -f -y

# 查找并复制 DTB 文件到 /boot/dtb/rockchip/
mkdir -p /boot/dtb/rockchip/overlay

# 查找 DTB 源目录（Armbian 内核 deb 通常安装在 /usr/lib/linux-image-*/ 或 /boot/dtb-*/）
DTB_SRC=""
for d in /usr/lib/linux-image-*/rockchip /boot/dtb-* /usr/lib/linux-image-*/; do
    if [[ -d "${d}" ]] && [[ -n "$(ls "${d}"/*.dtb 2>/dev/null)" ]]; then
        DTB_SRC="${d}"
        break
    fi
done

if [[ -n "${DTB_SRC}" ]]; then
    echo "[INFO] 找到 DTB 源目录: ${DTB_SRC}"
    cp -a "${DTB_SRC}"/*.dtb /boot/dtb/rockchip/ 2>/dev/null || true
    # 复制 overlay
    if [[ -d "${DTB_SRC}/overlay" ]]; then
        cp -a "${DTB_SRC}/overlay"/*.dtbo /boot/dtb/rockchip/overlay/ 2>/dev/null || true
    fi
    # 如果源目录本身就是 rockchip 子目录，也检查上级目录
    if [[ "${DTB_SRC}" == */rockchip ]]; then
        parent=$(dirname "${DTB_SRC}")
        if [[ -d "${parent}/overlay" ]]; then
            cp -a "${parent}/overlay"/*.dtbo /boot/dtb/rockchip/overlay/ 2>/dev/null || true
        fi
    fi
else
    echo "[WARN] 未找到 DTB 源目录，尝试全局搜索..."
    find /usr/lib/linux-image-* -name "*.dtb" -exec cp {} /boot/dtb/rockchip/ \; 2>/dev/null || true
    find /usr/lib/linux-image-* -name "*.dtbo" -exec cp {} /boot/dtb/rockchip/overlay/ \; 2>/dev/null || true
fi

# 列出已复制的 DTB
echo "[INFO] /boot/dtb/rockchip/ 内容:"
ls -la /boot/dtb/rockchip/ 2>/dev/null || echo "[WARN] 目录为空"
echo "[INFO] /boot/dtb/rockchip/overlay/ 内容:"
ls -la /boot/dtb/rockchip/overlay/ 2>/dev/null || echo "[WARN] overlay 目录为空"

# 清理
rm -rf /tmp/kernel-debs
apt-get clean
CHROOT_EOF

    umount -lf "${rootfs_dir}/tmp" 2>/dev/null || true
    umount -lf "${rootfs_dir}/proc" 2>/dev/null || true
    umount -lf "${rootfs_dir}/sys" 2>/dev/null || true
    umount -lf "${rootfs_dir}/dev" 2>/dev/null || true

    log_info "内核安装完成"
}

generate_extlinux() {
    log_step "生成 extlinux.conf..."
    local rootfs_dir="${WORKSPACE}/rootfs"
    local boot_dir="${rootfs_dir}/boot"

    local kernel_version
    kernel_version=$(ls "${boot_dir}"/vmlinuz-* 2>/dev/null | head -1 | sed 's/.*vmlinuz-//') || kernel_version="6.1.115"

    mkdir -p "${boot_dir}/extlinux"

    local dtb_path="/boot/dtb/rockchip/${KERNEL_DTB}"
    local overlay_path="/boot/dtb/rockchip/overlay/${KERNEL_OVERLAYS}"

    cat > "${boot_dir}/extlinux/extlinux.conf" <<EOF
# Deepin 25 Rockchip 多介质启动配置
# 生成时间: $(date)
# 板卡: ${BOARD}
#
# 启动设备对应关系:
#   eMMC  -> /dev/mmcblk0p1
#   SD    -> /dev/mmcblk1p1
#   NVMe  -> /dev/nvme0n1p1
#
# cma=512M: Panthor GPU / RKMPP 硬解码所需

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

    log_info "extlinux.conf 生成完成 (内核版本: ${kernel_version})"
}

create_image() {
    log_step "创建磁盘镜像..."
    local img_file="${OUTPUT}/deepin25-${BOARD}-$(date +%Y%m%d).img"
    local rootfs_dir="${WORKSPACE}/rootfs"

    local rootfs_size
    rootfs_size=$(du -sm "${rootfs_dir}" | cut -f1)
    local img_size=$((rootfs_size + 1024))

    fallocate -l "${img_size}M" "${img_file}"
    parted --script "${img_file}" mklabel gpt mkpart primary ext4 16MiB 100%

    export LOOP_DEV=$(losetup -f --show -P "${img_file}")
    local part_dev="${LOOP_DEV}p1"
    sleep 2

    local root_uuid
    root_uuid=$(uuidgen)
    root_uuid=$(echo "${root_uuid}" | tr '[:upper:]' '[:lower:]')
    mkfs.ext4 -F -U "${root_uuid}" -L root "${part_dev}"

    local mount_dir="${WORKSPACE}/img-mount"
    mkdir -p "${mount_dir}"
    mount "${part_dev}" "${mount_dir}"

    log_info "复制根文件系统到镜像..."
    rsync -aHAX --info=progress2 "${rootfs_dir}/" "${mount_dir}/"

    # 确保 fstab UUID 与实际分区一致
    sed -i "s|UUID=.* / .*ext4|UUID=${root_uuid} / ext4|" "${mount_dir}/etc/fstab"

    # 确保 fstab 包含正确的启动设备标识
    if ! grep -q "^UUID=" "${mount_dir}/etc/fstab" 2>/dev/null; then
        echo "UUID=${root_uuid} / ext4 defaults,noatime 0 1" >> "${mount_dir}/etc/fstab"
    fi

    sync
    umount "${mount_dir}"

    if [[ -f "${UBOOT_BIN}" ]]; then
        log_info "烧写 U-Boot 到镜像..."
        dd if="${UBOOT_BIN}" of="${LOOP_DEV}" seek=64 bs=512 conv=fsync status=progress
    fi

    losetup -d "${LOOP_DEV}"
    unset LOOP_DEV

    # 压缩镜像（可选）
    if [[ "${COMPRESS_IMG:-}" == "yes" ]]; then
        log_info "压缩镜像..."
        gzip -c "${img_file}" > "${img_file}.gz"
        rm -f "${img_file}"
        img_file="${img_file}.gz"
    fi

    chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "${img_file}" 2>/dev/null || true

    log_info "镜像创建完成: ${img_file}"
    ls -lh "${img_file}"
}

main() {
    log_info "========================================"
    log_info "Deepin 25 Rockchip 通用镜像构建系统 v2.0"
    log_info "目标板卡: ${BOARD}"
    log_info "========================================"

    check_prerequisites
    load_device_config
    prepare_sources
    build_tfa
    build_uboot
    build_kernel
    build_rootfs
    install_overlays
    configure_rootfs
    install_kernel
    generate_extlinux
    create_image

    log_info "========================================"
    log_info "构建完成!"
    log_info "输出目录: ${OUTPUT}"
    log_info "日志文件: ${LOG_FILE}"
    log_info "========================================"
}

main "$@"
