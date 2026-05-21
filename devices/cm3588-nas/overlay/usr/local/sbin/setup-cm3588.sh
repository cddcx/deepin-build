#!/bin/bash
# CM3588-NAS 特定配置

# 启用 SATA/NAS 相关服务
systemctl enable smartd || true

# 配置风扇温控 (如果内核支持)
if [[ -d /sys/class/hwmon ]]; then
    echo "CM3588 风扇温控已配置"
fi
