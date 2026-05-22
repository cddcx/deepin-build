# Deepin 25 Rockchip 通用镜像构建系统 v2.1 修复说明

## 修复概要

基于 [Deepin 官方 Orange Pi 5 Plus 移植教程](https://www.deepin.org/zh/deepin25-orangepi/) 和实际构建错误日志，对 `deepin-build` 进行了系统性修复。

---

## 主要修复点

### 1. 依赖安装修复（Ubuntu 24 / Debian 13 适配）

**问题**：`python3-distutils` 在 Ubuntu 24/Debian 13 中已移除，导致 `E: 软件包 python3-distutils 没有可安装候选`

**修复**：
- 替换为 `python3-setuptools` + `python3-dev`
- 增加 `usrmerge`、`uuid-runtime`（官方教程依赖）
- 增加系统版本检测 (`detect_os`)，自动适配新系统
- 依赖安装改为逐个检查，单个包失败不中断整体流程

### 2. mmdebstrap 修复

**问题**：`mmdebstrap failed to run`、卡住、包找不到

**修复**：
- 采用官方教程参数：`--hook-dir=/usr/share/mmdebstrap/hooks/merged-usr`、`--skip=check/empty`
- 正确的包列表（移除 Deepin 仓库不存在的 `firmware-realtek`、`rga2` 等）
- 增加 GPG Key 处理逻辑（非 Deepin 系统自动导入）
- 增加 `--keyring` 参数支持

### 3. U-Boot 编译修复

**问题**：`auto.conf` 错误、defconfig 找不到、`u-boot-rockchip.bin` 缺失

**修复**：
- 完整引入 **TF-A + rkbin + U-Boot** 三件套编译流程（参考官方教程）
- 自动搜索 DDR Blob（支持 v1.10 ~ v1.16 回退）
- 增强 defconfig 回退逻辑（支持 6 种命名变体）
- 使用 `ROCKCHIP_TPL` 和 `BL31` 环境变量编译
- 生成 `u-boot-rockchip.bin` 并写入镜像前部（`seek=1 bs=32k`）

### 4. 内核编译修复

**问题**：`aarch64-linux-gnu-gcc: fatal error: input file is the same as output file`、deb 重复、DTB 路径错误

**修复**：
- 使用 `make bindeb-pkg` 生成标准 deb 包（参考官方教程）
- 编译前清理旧 deb，避免冲突
- 自动清理重复内核 deb（只保留最新版本）
- 动态检测内核版本号，用于 extlinux.conf 生成
- 确保 DTB 路径指向 `/usr/lib/linux-image-$VERSION/rockchip/`

### 5. Rootfs 配置修复

**问题**：chroot 中包安装失败、权限不够、挂载残留

**修复**：
- 参考官方教程的 chroot 流程（mount bind dev/proc/sys/tmp）
- 使用 `DEBIAN_FRONTEND=noninteractive` 避免交互阻塞
- 桌面环境安装采用官方包列表：`deepin-desktop-environment-core/base/cli/extras firefox ddm treeland`
- **关键修复**：`systemctl disable lightdm && systemctl enable ddm`（参考官方教程）
- Rockchip 多媒体包改为**条件安装**（`rockchip-mpp`、`librga-dev` 等），不可用时不中断构建
- 增强挂载清理逻辑，使用 `umount -lf` 强制卸载，避免权限残留

### 6. 引导配置修复

**问题**：`/boot/dtb/rockchip/` 无文件、extlinux.conf 参数错误

**修复**：
- 动态生成 `extlinux.conf`，自动填入内核版本、DTB 路径、UUID
- 支持 `fdtoverlays`（如 `rockchip-rk3588-panthor-gpu.dtbo`）
- 参考官方教程的 `append` 参数：`cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory`
- 生成 `fstab` 使用 `x-systemd.growfs` 实现首次启动自动扩展

### 7. 镜像打包修复

**问题**：`log_step: 未找到命令`、rootfs 清空、二次打包失败

**修复**：
- 提取公共函数库 `scripts/common.sh`，统一日志函数（`log_step`、`log_ok`、`log_warn`、`log_error`）
- 镜像分区采用官方教程方案：GPT 分区表，前 16MB 预留，单根分区
- 二次打包脚本 `repack.sh` 正确调用 build.sh 的 Step 5-6
- 构建完成后可选生成 `rootfs-backup.tar.gz`

---

## 目录结构变化

```
deepin-build/
├── build.sh              # 主构建脚本（重写）
├── repack.sh             # 二次打包（修复）
├── build-all.sh          # 批量构建（修复）
├── backup-rootfs.sh      # 手动备份
├── scripts/
│   └── common.sh         # 公共函数库（新增，修复 log_step 等）
├── devices/
│   ├── rock-5-itx/
│   │   └── device.conf   # 板卡参数（修复 defconfig/dtb）
│   ├── cm3588-nas/
│   │   └── device.conf
│   ├── orange-pi-5-plus/
│   │   └── device.conf   # 参考官方教程配置
│   └── quartzpro64/
│       └── device.conf
└── overlay/common/       # 通用 overlay（修复权限和路径）
    ├── etc/systemd/system/expand-rootfs.service
    ├── usr/local/bin/expand-rootfs.sh
    ├── etc/initramfs-tools/scripts/init-premount/10-rockchip-pcie
    ├── etc/udev/rules.d/90-naming-audios.rules
    ├── etc/modprobe.d/panthor.conf
    └── etc/fstab
```

---

## 使用方法

### 全新使用

```bash
# 1. 克隆或替换文件到 deepin-build 目录
cd deepin-build

# 2. 安装依赖（脚本会自动检测系统版本）
sudo ./scripts/common.sh  # 或直接运行 build.sh，会自动安装

# 3. 构建单个板卡
sudo BOARD=rock-5-itx ./build.sh
sudo BOARD=orange-pi-5-plus ./build.sh

# 4. 批量构建
sudo ./build-all.sh

# 5. 二次打包（不重新编译 rootfs）
sudo BOARD=cm3588-nas ./repack.sh
```

### 从旧版本迁移

如果你已有 `deepin-build` 仓库，建议：

```bash
cd deepin-build
git checkout main

# 备份旧脚本
mkdir -p old-scripts
mv build.sh repack.sh build-all.sh backup-rootfs.sh old-scripts/

# 复制修复后的文件
cp -r /path/to/deepin-build-fixed/* .
chmod +x build.sh repack.sh build-all.sh backup-rootfs.sh scripts/common.sh

# 保留你的 devices/ 自定义 overlay（如有）
# 对比 device.conf 差异，合并自定义参数
```

---

## 关键参数说明

| 环境变量 | 说明 | 示例 |
|---------|------|------|
| `BOARD` | 目标板卡 | `rock-5-itx`, `orange-pi-5-plus` |
| `SKIP_ROOTFS` | 强制重新构建 rootfs | `1` |
| `FORCE_REBUILD_KERNEL` | 强制重新编译内核 | `1` |
| `SKIP_BACKUP` | 跳过 rootfs 备份 | `1` |
| `IMAGE_SIZE` | 输出镜像大小 | `8G` |

---

## 故障排查

### 1. mmdebstrap 仍然卡住

```bash
# 手动清理残留挂载
sudo umount -lf workspace/rootfs/{proc,sys,dev,tmp,var/tmp} 2>/dev/null
sudo rm -rf workspace/rootfs
# 然后重新构建
sudo BOARD=rock-5-itx ./build.sh
```

### 2. U-Boot defconfig 找不到

脚本已内置 6 种回退命名规则。如果仍失败，请检查：
```bash
cd cache/u-boot
ls configs/ | grep -i "你的板卡名"
# 然后在 devices/你的板卡/device.conf 中指定正确的 UBOOT_DEFCONFIG
```

### 3. 内核 deb 版本混乱

```bash
# 清理缓存重新编译
rm -rf cache/kernel-debs/*
sudo FORCE_REBUILD_KERNEL=1 BOARD=rock-5-itx ./build.sh
```

### 4. 桌面环境安装失败

某些 Deepin 包可能在 `crimson` 仓库中缺失，脚本会自动跳过并继续。启动后可手动安装：
```bash
sudo apt update
sudo apt install -y dde-desktop dde-dock dde-launcher
```

---

## 参考

- [Deepin 25 Orange Pi 5 Plus 官方移植教程](https://www.deepin.org/zh/deepin25-orangepi/)
- [Armbian linux-rockchip 内核](https://github.com/armbian/linux-rockchip)
- [U-Boot 官方仓库](https://github.com/u-boot/u-boot)
- [Trusted Firmware-A](https://github.com/TrustedFirmware-A/trusted-firmware-a)
