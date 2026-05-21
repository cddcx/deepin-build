# Deepin 25 Rockchip 通用多板卡镜像构建系统

## 快速开始

```bash
# 安装依赖
sudo apt install -y mmdebstrap qemu-user-static systemd-container binfmt-support \
    parted kpartx dosfstools e2fsprogs rsync git curl gpg \
    build-essential crossbuild-essential-arm64 libncurses-dev \
    swig flex bison u-boot-tools bc libssh-dev kmod cpio \
    libelf-dev libssl-dev dwarves python3-pyelftools

# 构建 ROCK 5 ITX
sudo BOARD=rock-5-itx ./build.sh

# 构建 CM3588-NAS
sudo BOARD=cm3588-nas ./build.sh
```

## 智能 rootfs 管理

| 场景 | 命令 | 行为 |
|------|------|------|
| 同板卡增量构建 | `sudo BOARD=rock-5-itx ./build.sh` | 直接使用现有 rootfs |
| 跨板卡复用 | `sudo rm -rf workspace/rootfs && sudo BOARD=cm3588-nas ./build.sh` | 自动解压备份 |
| 全新构建 | `sudo rm -rf workspace/rootfs workspace/*.tar.gz && sudo BOARD=rock-5-itx ./build.sh` | 执行 mmdebstrap |
| 强制重建 | `sudo SKIP_ROOTFS=1 BOARD=rock-5-itx ./build.sh` | 忽略现有 rootfs |

## 二次打包

```bash
# 方式1: 使用 repack.sh
sudo BOARD=rock-5-itx ./repack.sh

# 方式2: 使用 build.sh（自动检测备份）
sudo rm -rf workspace/rootfs
sudo BOARD=rock-5-itx ./build.sh

# 方式3: 手动备份后打包
sudo ./backup-rootfs.sh
sudo rm -rf workspace/rootfs
sudo tar xzf workspace/rootfs-backup-*.tar.gz -C workspace/rootfs/
sudo BOARD=rock-5-itx ./repack.sh
```

## 刷机

```bash
# SD 卡
sudo dd if=output/deepin25-rock-5-itx-*.img of=/dev/sdX bs=4M status=progress conv=fsync

# eMMC (Maskrom)
rkdeveloptool db rk3588_spl_loader.bin
rkdeveloptool wl 0 output/deepin25-rock-5-itx-*.img
rkdeveloptool rd
```

## 启动设备选择

启动时按任意键进入 U-Boot 菜单：
- **Deepin-SD** (默认) - SD 卡启动
- **Deepin-eMMC** - eMMC 启动
- **Deepin-NVMe** - NVMe SSD 启动
- **Deepin-Recovery** - 恢复模式

## 支持的板卡

- ROCK 5 ITX
- CM3588-NAS
- Orange Pi 5 Plus
- 可自定义添加

## 修复记录

- DDR 固件自动搜索
- U-Boot defconfig 回退
- 内核 defconfig 检测 (rockchip_linux_defconfig)
- 固件包容错 (mmdebstrap 最小包集)
- tar 备份排除虚拟文件系统
- 内核 deb 重复清理
- UUID 一致性 (/dev/mmcblkXp1)
- dtb 自动复制到 /boot/dtb/rockchip/
- initramfs 存储驱动
- GPU/HDMI 配置 (ddm/treeland)
- pipefail 兼容性
