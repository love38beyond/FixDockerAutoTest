#!/usr/bin/env bash
# download_offline_deps.sh — 在联网 Linux 机器上运行，下载离线依赖包
# 用法: bash download_offline_deps.sh [python_version]
# 默认: Python 3.6
#
# 输出: softpackage/offline-linux-py36.tar.gz (或对应版本)
# 将此文件复制到离线机器解压后即可安装

set -euo pipefail

PY_VER="${1:-3.6}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/../FixAutoTest/FixAutoTest/softpackage"
OUTPUT="$PKG_DIR/offline-linux-py${PY_VER/./}.tar.gz"
TEMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

echo "========================================="
echo "  下载 Python ${PY_VER} 离线依赖包"
echo "========================================="
echo ""

# 检测 Python
PYTHON=$(command -v "python${PY_VER}" || command -v "python3" || command -v "python")
if ! $PYTHON --version 2>&1 | grep -q "$PY_VER"; then
    echo "错误: 需要 Python ${PY_VER}，当前: $($PYTHON --version)"
    echo "请先安装 Python ${PY_VER} 再运行本脚本"
    exit 1
fi
echo "Python: $($PYTHON --version)"

# 确保 pip 可用
$PYTHON -m pip --version &>/dev/null || $PYTHON -m ensurepip

echo ""
echo "下载依赖包到临时目录..."

# 下载 quickfix（依次尝试不同 manylinux 平台）
download_quickfix_wheel() {
    for platform in manylinux1_x86_64 manylinux2010_x86_64 manylinux2014_x86_64; do
        echo "尝试 $platform ..."
        if $PYTHON -m pip download \
            --platform "$platform" \
            --python-version "$PY_VER" \
            --implementation cp \
            --abi "cp${PY_VER/./}m" \
            --only-binary=:all: \
            --dest "$TEMP_DIR" \
            quickfix==1.15.1 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

if ! download_quickfix_wheel; then
    echo ""
    echo "警告: 未找到 quickfix 预编译 wheel，下载源码包（需在目标机器编译）"
    echo "      目标机器必须安装 python-devel 和 gcc-c++ 才能编译"
    echo "      CentOS: yum install -y python${PY_VER/./}-devel gcc-c++"
    echo ""
    $PYTHON -m pip download \
        --no-binary=:all: \
        --dest "$TEMP_DIR" \
        quickfix==1.15.1
fi

# 下载 xlrd（纯 Python，通用）
$PYTHON -m pip download \
    --dest "$TEMP_DIR" \
    xlrd==1.2.0

echo ""
echo "下载完成，文件列表:"
ls -lh "$TEMP_DIR"

# 打包
echo ""
echo "打包为: $OUTPUT"
mkdir -p "$PKG_DIR"
tar czf "$OUTPUT" -C "$TEMP_DIR" .

echo ""
echo "========================================="
echo "  完成!"
echo "========================================="
echo ""
echo "离线包: $OUTPUT"
echo ""
echo "部署到离线机器:"
echo "  1. 复制到目标机器"
echo "  2. tar xzf offline-linux-py${PY_VER/./}.tar.gz -C /tmp/fix-packages/"
echo "  3. pip install --no-index --find-links=/tmp/fix-packages/ quickfix xlrd"
echo ""
