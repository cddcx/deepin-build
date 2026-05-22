# Deepin 25 Rockchip 通用多板卡镜像构建系统

整合参考仓库:
- [xiaobao1980/deepin-build](https://github.com/xiaobao1980/deepin-build) - 基础构建框架
- [YukariChiba/deepin-ports-image](https://github.com/YukariChiba/deepin-ports-image) - Deepin 移植镜像工具
- [deepin-community/deepin-ports-kernel](https://github.com/deepin-community/deepin-ports-kernel) - Deepin 移植内核
- [xiaobao1980/armbian-build](https://github.com/xiaobao1980/armbian-build) - Armbian 构建框架 (board/family 配置参考)
- [deepin.org deepin25-orangepi](https://www.deepin.org/zh/deepin25-orangepi/) - 官方 Deepin 25 香橙派

## 特性

- **多板卡支持**: ROCK 5 ITX, CM3588-NAS, Orange Pi 5 Plus, QuartzPro64 等
- **多介质启动**: SD 卡 / NVMe SSD / eMMC (U-Boot 启动顺序 + extlinux 菜单)
- **Armbian 配置参考**: 自动调用 `armbian-build/config/boards/` 和 `config/sources/families/` 的板卡参数
- **智能 rootfs 管理**: 同板卡复用 / 跨板卡备份 / 全新构建
- **二次打包**: 不重新编译根文件系统，快速生成新镜像
- **批量构建**: 一键构建所有板卡镜像
- **GPU/HDMI 优化**: Panthor GPU, RKMPP 硬解码, cma=512M
- **GitHub Actions CI**: 矩阵构建 + 自动 Release

## 快速开始

### 安装依赖

```bash
sudo apt install -y mmdebstrap qemu-user-static systemd-container binfmt-support \
    parted kpartx dosfstools e2fsprogs rsync git curl gpg \
    build-essential crossbuild-essential-arm64 libncurses-dev \
    swig flex bison u-boot-tools bc libssh-dev kmod cpio \
    libelf-dev libssl-dev dwarves python3-pyelftools python3-setuptools python3-dev libgnutls28-dev
```

### 构建单个板卡

```bash
# 构建 ROCK 5 ITX
sudo BOARD=rock-5-itx ./build.sh

# 构建 CM3588-NAS
sudo BOARD=cm3588-nas ./build.sh

# 构建 Orange Pi 5 Plus
sudo BOARD=orange-pi-5-plus ./build.sh

# 构建 QuartzPro64
sudo BOARD=quartzpro64 ./build.sh
```

### 批量构建所有板卡

```bash
# 构建所有支持的板卡（第一个完整构建，后续复用 rootfs）
sudo ./build-all.sh

# 或指定部分板卡
sudo ./build-all.sh rock-5-itx cm3588-nas
```

### 二次打包（不重新编译 rootfs）

```bash
sudo BOARD=rock-5-itx ./repack.sh
```

### 手动备份 rootfs

```bash
sudo ./backup-rootfs.sh
```

### 刷机

```bash
# SD 卡
sudo dd if=output/deepin25-rock-5-itx-*.img of=/dev/sdX bs=4M status=progress conv=fsync

# eMMC (Maskrom 模式)
rkdeveloptool db rk3588_spl_loader.bin
rkdeveloptool wl 0 output/deepin25-rock-5-itx-*.img
rkdeveloptool rd
```

## 启动设备选择

启动时按任意键进入 U-Boot 菜单:

- **Deepin-SD** (默认) - SD 卡启动 (`/dev/mmcblk1p1`)
- **Deepin-eMMC** - eMMC 启动 (`/dev/mmcblk0p1`)
- **Deepin-NVMe** - NVMe SSD 启动 (`/dev/nvme0n1p1`)
- **Deepin-Recovery** - 恢复模式

## 目录结构

```
.
├── build.sh                    # 主构建脚本
├── repack.sh                   # 二次打包脚本
├── build-all.sh                # 批量构建脚本
├── backup-rootfs.sh            # 手动备份 rootfs
├── devices/                    # 板卡配置目录
│   ├── rock-5-itx/
│   │   ├── device.conf         # 板卡参数
│   │   └── overlay/            # 板卡专属 overlay
│   │       ├── etc/udev/rules.d/91-rock5itx-audio.rules
│   │       └── ...
│   ├── cm3588-nas/
│   │   ├── device.conf
│   │   └── overlay/
│   │       ├── etc/sysctl.d/99-nas-tuning.conf
│   │       └── etc/samba/smb.conf
│   ├── orange-pi-5-plus/
│   │   ├── device.conf
│   │   └── overlay/
│   │       ├── usr/local/bin/fan-control.sh
│   │       └── etc/systemd/system/fan-control.service
│   └── quartzpro64/
│       └── device.conf
├── overlay/common/             # 通用 overlay
│   ├── etc/systemd/system/expand-rootfs.service
│   ├── usr/local/bin/expand-rootfs.sh
│   ├── etc/initramfs-tools/scripts/init-premount/10-rockchip-pcie
│   ├── etc/udev/rules.d/90-naming-audios.rules
│   ├── etc/modprobe.d/panthor.conf
│   └── etc/fstab
├── .github/workflows/           # GitHub Actions CI
│   └── build.yml
├── workspace/                  # 构建工作目录 (自动生成)
│   ├── rootfs/                 # 根文件系统
│   └── rootfs-backup-*.tar.gz # rootfs 备份
├── cache/                      # 源码/固件缓存 (自动生成)
│   ├── rkbin/                  # Rockchip 固件二进制
│   ├── u-boot/                 # U-Boot 源码
│   ├── trusted-firmware-a/     # TF-A 源码
│   ├── linux-rockchip/         # 内核源码
│   └── kernel-debs/            # 编译好的内核 deb 包
└── output/                     # 输出目录 (自动生成)
    └── deepin25-*.img          # 最终镜像
```

## 智能 rootfs 管理

| 场景 | 命令 | 行为 |
|------|------|------|
| 同板卡增量构建 | `sudo BOARD=rock-5-itx ./build.sh` | 直接使用现有 rootfs |
| 跨板卡复用 | `sudo rm -rf workspace/rootfs && sudo BOARD=cm3588-nas ./build.sh` | 自动解压备份 |
| 全新构建 | `sudo rm -rf workspace/rootfs workspace/*.tar.gz && sudo BOARD=rock-5-itx ./build.sh` | 执行 mmdebstrap |
| 强制重建 | `sudo SKIP_ROOTFS=1 BOARD=rock-5-itx ./build.sh` | 忽略现有 rootfs |
| 手动备份 | `sudo ./backup-rootfs.sh` | 生成 tar.gz 备份 |

## 添加新板卡

1. 在 `devices/` 下创建新目录，如 `devices/my-board/`
2. 创建 `device.conf`:

```bash
BOARD_NAME="My Board"
BOARD_SOC="rk3588"
UBOOT_DEFCONFIG="my-board-rk3588_defconfig"
KERNEL_DTB="rk3588-my-board.dtb"
KERNEL_OVERLAYS=""
KERNEL_REPO="https://github.com/armbian/linux-rockchip"
KERNEL_BRANCH="rk-6.1-rkr5.1"
EXTRA_PACKAGES="pciutils,usbutils"
```

3. 可选: 添加板卡专属 overlay 到 `devices/my-board/overlay/`
4. 执行: `sudo BOARD=my-board ./build.sh`

## 板卡专属特性

### ROCK 5 ITX
- 音频设备精确命名 (HDMI1/DP0/DP1/ES8316)
- Panthor GPU overlay 自动加载
- 支持 SPI Flash U-Boot 环境

### CM3588-NAS
- NAS 网络优化 (BBR, 大缓冲区)
- Samba 预配置
- 额外安装: samba, nfs-common, mdadm, lvm2

### Orange Pi 5 Plus
- PWM 风扇自动控制
- 温度阈值: 55°C/70°C/85°C

## 技术细节

### U-Boot 启动顺序 (参考 Armbian)

```c
// include/configs/rockchip-common.h
#define BOOT_TARGETS "mmc1 nvme mmc0 scsi usb pxe dhcp spi"
```

- `mmc1` = SD 卡
- `nvme` = NVMe SSD
- `mmc0` = eMMC

### 内核源

默认使用 Armbian `linux-rockchip` 仓库:
- 分支: `rk-6.1-rkr5.1`
- defconfig: `rockchip_linux_defconfig`

可替换为 `deepin-community/deepin-ports-kernel`:
```bash
KERNEL_REPO="https://github.com/deepin-community/deepin-ports-kernel"
KERNEL_BRANCH="master"
```

### 根文件系统

使用 `mmdebstrap` 构建 Deepin 25 (crimson) 根文件系统:
- 源: `https://community-packages.deepin.com/beige/`
- 架构: `arm64`
- 包含: DDE 桌面环境, NetworkManager, systemd, ssh, Rockchip 多媒体包

## GitHub Actions CI

项目包含完整的 GitHub Actions 工作流:

1. **build-rootfs**: 构建基础 rootfs 并缓存
2. **build-images**: 矩阵构建所有板卡镜像
3. **release**: 自动创建 GitHub Release

触发方式:
- Push 到 main 分支
- Pull Request
- 手动触发 (workflow_dispatch)

## 故障排查

### U-Boot defconfig 找不到
脚本会自动尝试以下回退:
1. `${BOARD}_defconfig`
2. `rock-5-itx-rk3588_defconfig`
3. `rock5-rk3588_defconfig`
4. `rock5b-rk3588_defconfig`

### 内核 deb 重复
脚本会自动清理旧版本，只保留每个包的最新版本。

### mmdebstrap 失败
检查 `workspace/` 下是否有残留挂载:
```bash
sudo umount -lf workspace/rootfs/{proc,sys,dev,tmp} 2>/dev/null || true
```

### 构建日志
所有构建日志保存在 `output/build-*.log`，可用于故障分析。

## License

MIT License - 详见 [LICENSE](LICENSE)
