#!/bin/bash
# ROCK 5 ITX 板级支持配置
# 包含 Rockchip 编解码器支持和 deepin-ports 仓库配置

set -e

echo "[setup] 配置 ROCK 5 ITX 板级支持..."

# 安装 Rockchip 编解码器支持（来自 deepin-ports 仓库）
# 注意：ports-board-rockchip 仓库提供 Rockchip 的编解码器支持
for pkg in rockchip-mpp-drm rockchip-mpp-sample rockchip-mpp-dev; do
    apt-get install -y "${pkg}" 2>/dev/null || echo "[WARN] ${pkg} 不可用"
done

# 配置 GPU 权限
cat > /etc/udev/rules.d/99-rk-device-permissions.rules <<'EOF'
# Rockchip VPU/RGA/GPU 设备权限
KERNEL=="mpp_service", MODE="0666", GROUP="video"
KERNEL=="rga", MODE="0666", GROUP="video"
KERNEL=="rknpu", MODE="0666", GROUP="video"
KERNEL=="rknpu0", MODE="0666", GROUP="video"
KERNEL=="rknpu1", MODE="0666", GROUP="video"
KERNEL=="rknpu2", MODE="0666", GROUP="video"
KERNEL=="dri/card*", MODE="0666", GROUP="video"
KERNEL=="dri/renderD*", MODE="0666", GROUP="render"
EOF

# 将用户加入视频和渲染组
usermod -a -G video,render,audio,input deepin 2>/dev/null || true

echo "[setup] ROCK 5 ITX 板级支持配置完成"
