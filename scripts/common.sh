#!/bin/bash
# Deepin 25 Rockchip Build - Common Functions (Fixed)
# 修复点：增加 robust 错误处理、日志函数、依赖检查

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数（修复 log_step 未找到错误）
log_step() {
    echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $1"
}

log_ok() {
    echo -e "${GREEN}[OK]${NC}   $(date '+%H:%M:%S') $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1"
}

die() {
    log_error "$1"
    exit 1
}

# 检测系统版本以适配包名
 detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION_ID="$VERSION_ID"
        OS_CODENAME="$VERSION_CODENAME"
    else
        OS_ID="unknown"
        OS_VERSION_ID="unknown"
        OS_CODENAME="unknown"
    fi
}

# 修复依赖安装：适配 Ubuntu 24 / Debian 13 包名变化
install_dependencies() {
    log_step "检查并安装构建依赖..."

    detect_os
    log_step "检测到系统: $OS_ID $OS_VERSION_ID ($OS_CODENAME)"

    # 基础包列表（参考官方教程 + 适配新版本）
    local PKGS=(
        mmdebstrap qemu-user-static binfmt-support systemd-container
        parted kpartx dosfstools e2fsprogs rsync git curl gpg
        build-essential crossbuild-essential-arm64 libncurses-dev
        swig flex bison u-boot-tools bc libssh-dev kmod cpio
        libelf-dev libssl-dev dwarves python3-pyelftools
        python3-setuptools python3-dev libgnutls28-dev
        usrmerge uuid-runtime
    )

    # Ubuntu 24+ / Debian 13+ 适配
    if [[ "$OS_VERSION_ID" =~ ^(24|25|13|14) ]] || [[ "$OS_CODENAME" =~ ^(noble|oracular|trixie|forky) ]]; then
        # python3-distutils 已移除，用 python3-setuptools 替代（已包含）
        # binfmt-support 在 Ubuntu 24 中可能被 systemd-binfmt 功能取代，但仍保留兼容
        log_step "应用 Ubuntu 24+/Debian 13+ 包名适配..."
    fi

    # 尝试安装，忽略个别包失败（如某些包在新版本中改名）
    for pkg in "${PKGS[@]}"; do
        if dpkg -l "$pkg" &>/dev/null || apt-cache show "$pkg" &>/dev/null; then
            apt-get install -y "$pkg" 2>/dev/null || log_warn "包 $pkg 安装失败，跳过"
        else
            log_warn "包 $pkg 在仓库中不可用，跳过"
        fi
    done

    # 确保 binfmt 已注册
    if [ -f /usr/sbin/update-binfmts ]; then
        update-binfmts --display qemu-aarch64 &>/dev/null || \
            log_warn "qemu-aarch64 binfmt 可能未注册，尝试修复..."
    fi

    # 检查交叉编译器
    if ! command -v aarch64-linux-gnu-gcc &>/dev/null; then
        die "aarch64-linux-gnu-gcc 未安装，请安装 crossbuild-essential-arm64"
    fi

    log_ok "依赖检查完成"
}

# 清理挂载（修复权限不够问题）
cleanup_mounts() {
    local rootfs_dir="$1"
    log_step "清理挂载点..."

    if [ -d "$rootfs_dir" ]; then
        # 使用 umount -lf 强制卸载，忽略错误
        umount -lf "${rootfs_dir}/proc" 2>/dev/null || true
        umount -lf "${rootfs_dir}/sys" 2>/dev/null || true
        umount -lf "${rootfs_dir}/dev/pts" 2>/dev/null || true
        umount -lf "${rootfs_dir}/dev" 2>/dev/null || true
        umount -lf "${rootfs_dir}/tmp" 2>/dev/null || true
        umount -lf "${rootfs_dir}/var/tmp" 2>/dev/null || true
    fi

    # 清理 loop 设备
    losetup -D 2>/dev/null || true

    log_ok "挂载清理完成"
}

# 获取可用 DDR 固件路径（修复 rkbin 搜索逻辑）
find_ddr_blob() {
    local rkbin_dir="$1"
    local soc="${2:-rk3588}"

    # 优先搜索常见命名
    local candidates=(
        "${rkbin_dir}/rk35/${soc}_ddr_lp4_2112MHz_lp5_2736MHz_v1.16.bin"
        "${rkbin_dir}/rk35/${soc}_ddr_lp4_2112MHz_lp5_2736MHz_v1.15.bin"
        "${rkbin_dir}/rk35/${soc}_ddr_lp4_2112MHz_lp5_2736MHz_v1.14.bin"
        "${rkbin_dir}/rk35/${soc}_ddr_lp4_2112MHz_lp5_2736MHz_v1.13.bin"
        "${rkbin_dir}/rk35/${soc}_ddr_lp4_2112MHz_lp5_2736MHz_v1.12.bin"
        "${rkbin_dir}/rk35/${soc}_ddr_lp4_2112MHz_lp5_2736MHz_v1.11.bin"
        "${rkbin_dir}/rk35/${soc}_ddr_lp4_2112MHz_lp5_2736MHz_v1.10.bin"
    )

    for f in "${candidates[@]}"; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done

    # 通配搜索
    local found=$(find "${rkbin_dir}" -name "${soc}_ddr*.bin" -type f 2>/dev/null | sort -V | tail -n1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

# 获取内核版本号（从 deb 文件名或源码目录）
get_kernel_version() {
    local kernel_debs_dir="$1"
    local deb=$(ls -1 "${kernel_debs_dir}"/linux-image-*.deb 2>/dev/null | head -n1)
    if [ -n "$deb" ]; then
        basename "$deb" | sed -E 's/linux-image-([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
        return 0
    fi
    echo "6.1.115"
}

# 板卡配置加载
load_board_config() {
    local board="${1:-$BOARD}"
    local config_file="${SCRIPT_DIR}/devices/${board}/device.conf"

    if [ ! -f "$config_file" ]; then
        die "板卡配置未找到: $config_file"
    fi

    source "$config_file"

    # 设置默认值
    BOARD_NAME="${BOARD_NAME:-$board}"
    BOARD_SOC="${BOARD_SOC:-rk3588}"
    KERNEL_REPO="${KERNEL_REPO:-https://github.com/armbian/linux-rockchip}"
    KERNEL_BRANCH="${KERNEL_BRANCH:-rk-6.1-rkr5.1}"
    UBOOT_REPO="${UBOOT_REPO:-https://github.com/u-boot/u-boot}"
    UBOOT_BRANCH="${UBOOT_BRANCH:-v2025.07}"
    TFA_REPO="${TFA_REPO:-https://github.com/TrustedFirmware-A/trusted-firmware-a}"
    TFA_BRANCH="${TFA_BRANCH:-v2.13.0}"
    RKBIN_REPO="${RKBIN_REPO:-https://github.com/armbian/rkbin}"
    RKBIN_BRANCH="${RKBIN_BRANCH:-master}"
}

# 导出函数
export -f log_step log_ok log_warn log_error die
export -f detect_os install_dependencies cleanup_mounts
export -f find_ddr_blob get_kernel_version load_board_config
