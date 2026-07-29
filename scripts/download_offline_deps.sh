#!/usr/bin/env bash
# download_offline_deps.sh — 在联网 Linux 机器上运行，下载/编译离线依赖包
# 用法: bash download_offline_deps.sh [python_version] [--build]
#   python_version: 默认 3.6
#   --build: 在本地编译 quickfix 为 wheel（需 python-devel + gcc-c++）
#            用于 PyPI 无预编译包时，本机编译后给离线目标机器使用
#
# 输出: softpackage/offline-linux-py36.tar.gz (或对应版本)

set -euo pipefail

BUILD_MODE=false
PY_VER="3.6"

for arg in "$@"; do
    case "$arg" in
        --build) BUILD_MODE=true ;;
        *) PY_VER="$arg" ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/../FixAutoTest/FixAutoTest/softpackage"
OUTPUT="$PKG_DIR/offline-linux-py${PY_VER/./}.tar.gz"
TEMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

echo "========================================="
if [ "$BUILD_MODE" = true ]; then
    echo "  编译 Python ${PY_VER} 离线依赖包（本地编译）"
else
    echo "  下载 Python ${PY_VER} 离线依赖包"
fi
echo "========================================="
echo ""

# 检测 Python
PYTHON=$(command -v "python${PY_VER}" || command -v "python3" || command -v "python")
if ! $PYTHON --version 2>&1 | grep -q "$PY_VER"; then
    echo "错误: 需要 Python ${PY_VER}，当前: $($PYTHON --version)"
    exit 1
fi
echo "Python: $($PYTHON --version)"

# 确保 pip 可用
$PYTHON -m pip --version &>/dev/null || $PYTHON -m ensurepip

echo ""
echo "准备依赖包到临时目录..."

# ---- 下载/编译 quickfix ----
if [ "$BUILD_MODE" = true ]; then
    echo ""
    echo "=== 本地编译模式 ==="
    echo "在当前机器编译 quickfix wheel..."
    echo "要求: python${PY_VER/./}-devel + gcc-c++ 已安装"
    echo ""
    $PYTHON -m pip wheel --wheel-dir "$TEMP_DIR" quickfix==1.15.1
    echo "编译完成"
else
    echo "尝试下载预编译 wheel..."
    WHEEL_OK=false
    for platform in manylinux1_x86_64 manylinux2010_x86_64 manylinux2014_x86_64; do
        echo "  尝试 $platform ..."
        if $PYTHON -m pip download \
            --platform "$platform" \
            --python-version "$PY_VER" \
            --implementation cp \
            --abi "cp${PY_VER/./}m" \
            --only-binary=:all: \
            --dest "$TEMP_DIR" \
            quickfix==1.15.1 2>/dev/null; then
            WHEEL_OK=true
            echo "  成功"
            break
        fi
    done
    if [ "$WHEEL_OK" = false ]; then
        echo ""
        echo "========================================="
        echo "  未找到 quickfix 预编译 wheel"
        echo "========================================="
        echo ""
        echo "请使用 --build 模式在**联网且安装了编译环境**的机器上编译："
        echo ""
        echo "  # 1. 安装编译环境"
        echo "  yum install -y python${PY_VER/./}-devel gcc-c++"
        echo ""
        echo "  # 2. 编译 wheel"
        echo "  bash $0 $PY_VER --build"
        echo ""
        echo "  # 3. 将生成的 $OUTPUT 复制到目标机器安装"
        echo "========================================="
        exit 1
    fi
fi

# ---- 下载 xlrd（纯 Python，通用）----
$PYTHON -m pip download --dest "$TEMP_DIR" xlrd==1.2.0

echo ""
echo "文件列表:"
ls -lh "$TEMP_DIR"

# ---- 打包 ----
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
if [ "$BUILD_MODE" = true ]; then
    echo "此包由本机编译，仅适用于相同 OS/Python 版本的目标机器"
    echo ""
fi
echo "部署到目标机器:"
echo "  1. 复制到目标机器"
echo "  2. tar xzf offline-linux-py${PY_VER/./}.tar.gz -C /tmp/fix-pkgs/"
echo "  3. pip install --no-index --find-links=/tmp/fix-pkgs/ quickfix xlrd"
echo ""
