#!/bin/bash
# 清理 cache/kernel-debs/ 中的重复/旧版本 deb 包

set -e

DEB_DIR="${1:-./cache/kernel-debs}"

if [[ ! -d "${DEB_DIR}" ]]; then
    echo "目录不存在: ${DEB_DIR}"
    exit 1
fi

echo "=== 清理前 ==="
ls -lh "${DEB_DIR}"/*.deb 2>/dev/null | awk '{print $9, $5}'

declare -A latest_deb

# 遍历所有 deb 包，按基础包名分组
for deb in $(ls -1 "${DEB_DIR}"/*.deb 2>/dev/null | sort -V); do
    basename_pkg=$(basename "${deb}" | sed 's/_[^_]*_arm64\.deb$//')
    latest_deb["${basename_pkg}"]="${deb}"
done

# 删除非最新版本
for deb in $(ls -1 "${DEB_DIR}"/*.deb 2>/dev/null | sort -V); do
    basename_pkg=$(basename "${deb}" | sed 's/_[^_]*_arm64\.deb$//')
    if [[ "${deb}" != "${latest_deb[${basename_pkg}]}" ]]; then
        echo "删除旧版本: $(basename "${deb}")"
        rm -f "${deb}"
    fi
done

echo ""
echo "=== 清理后 ==="
ls -lh "${DEB_DIR}"/*.deb 2>/dev/null | awk '{print $9, $5}'
