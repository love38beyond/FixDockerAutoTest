#!/usr/bin/env bash
# install_offline.sh — 在离线 Linux 机器上运行，从本地 wheel 包安装依赖
# 用法: bash install_offline.sh [python_bin]
# 默认: python3

set -euo pipefail

PYTHON="${1:-python3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/softpackage"

echo "========================================="
echo "  离线安装 Python 依赖"
echo "========================================="
echo ""
echo "Python: $($PYTHON --version 2>/dev/null || echo '未找到')"
echo ""

# 检查 Python
if ! $PYTHON --version &>/dev/null; then
    echo "错误: 找不到 $PYTHON"
    exit 1
fi

# 确保 pip 可用
if ! $PYTHON -m pip --version &>/dev/null; then
    echo "安装 pip..."
    $PYTHON -m ensurepip 2>/dev/null || {
        echo "错误: 无法安装 pip，请先手动安装"
        exit 1
    }
fi

# 方案 A: 使用预编译的离线包（推荐）
for tarball in "$PKG_DIR"/offline-linux-py*.tar.gz; do
    if [ -f "$tarball" ]; then
        echo "发现离线包: $(basename "$tarball")"
        TEMP_DIR=$(mktemp -d)
        tar xzf "$tarball" -C "$TEMP_DIR"
        echo "安装 quickfix + xlrd..."
        $PYTHON -m pip install --no-index --find-links="$TEMP_DIR" quickfix xlrd
        rm -rf "$TEMP_DIR"
        echo "安装完成"
        exit 0
    fi
done

# 方案 B: 回退到 softpackage 目录中的单个 wheel 文件
echo "未找到离线 tarball，尝试从 softpackage/ 直接安装..."

INSTALLED=false

# xlrd (纯 Python，通用 wheel)
XLRD_WHEEL=$(ls "$PKG_DIR"/xlrd-*.whl 2>/dev/null | head -1)
if [ -n "$XLRD_WHEEL" ]; then
    echo "安装 xlrd: $(basename "$XLRD_WHEEL")"
    $PYTHON -m pip install "$XLRD_WHEEL"
    INSTALLED=true
fi

# quickfix (检查是否有 Linux wheel)
QUICKFIX_LINUX=$(ls "$PKG_DIR"/quickfix-*-linux*.whl "$PKG_DIR"/quickfix-*-manylinux*.whl 2>/dev/null | head -1)
if [ -n "$QUICKFIX_LINUX" ]; then
    echo "安装 quickfix (Linux wheel): $(basename "$QUICKFIX_LINUX")"
    $PYTHON -m pip install "$QUICKFIX_LINUX"
    INSTALLED=true
elif ls "$PKG_DIR"/quickfix-*.tar.gz &>/dev/null; then
    # 源码包 — 需要编译
    echo "安装 quickfix (源码编译)..."
    # 检查 Python 开发头文件
    PY_VER=$($PYTHON -c 'import sys; print("{}.{}".format(sys.version_info.major, sys.version_info.minor))')
    if ! $PYTHON -c 'import sysconfig; print(sysconfig.get_config_var("INCLUDEPY"))' &>/dev/null; then
        PY_INCLUDE=$($PYTHON -c 'import sysconfig; print(sysconfig.get_config_var("INCLUDEPY") or "")')
        if [ ! -f "${PY_INCLUDE}/Python.h" ]; then
            echo ""
            echo "错误: 缺少 Python 开发头文件 (Python.h)"
            echo "离线环境请在有网络的机器上重新下载预编译包:"
            echo "  bash scripts/download_offline_deps.sh ${PY_VER}"
            echo ""
            echo "联网环境请先安装 python-devel:"
            echo "  CentOS/RHEL: yum install -y python${PY_VER/./}-devel"
            echo "  Ubuntu/Debian: apt-get install -y python${PY_VER/./}-dev"
            exit 1
        fi
    fi
    echo "编译环境检查通过，正在编译..."
    QUICKFIX_SRC=$(ls "$PKG_DIR"/quickfix-*.tar.gz | head -1)
    $PYTHON -m pip install "$QUICKFIX_SRC"
    INSTALLED=true
else
    echo "错误: 未找到 Linux 兼容的 quickfix 包"
    echo ""
    echo "解决方案:"
    echo "  1. 在联网 Linux 机器上运行: bash scripts/download_offline_deps.sh"
    echo "  2. 将生成的 tar.gz 复制到本机 softpackage/ 目录"
    echo "  3. 重新运行本脚本"
    exit 1
fi

if [ "$INSTALLED" = true ]; then
    echo ""
    echo "========================================="
    echo "  验证安装"
    echo "========================================="
    PASS=0
    FAIL=0

    # 1. quickfix 导入 + 版本
    echo -n "quickfix 导入 ... "
    if $PYTHON -c "import quickfix; print(quickfix.__version__)" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "quickfix: 失败"
        FAIL=$((FAIL + 1))
    fi

    # 2. quickfix C++ 扩展
    echo -n "quickfix C++ 扩展 ... "
    if $PYTHON -c "import _quickfix" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "失败（缺少 _quickfix.so，编译可能不完整）"
        FAIL=$((FAIL + 1))
    fi

    # 3. quickfix 核心功能
    echo -n "quickfix 核心功能 ... "
    if $PYTHON -c "
import quickfix as fix
msg = fix.Message()
msg.getHeader().setField(fix.BeginString('FIX.4.2'))
msg.getHeader().setField(fix.MsgType('D'))
assert msg.toString() != ''
" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "失败"
        FAIL=$((FAIL + 1))
    fi

    # 4. xlrd 导入 + 版本
    echo -n "xlrd 导入 ... "
    if $PYTHON -c "import xlrd; print(xlrd.__VERSION__)" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "xlrd: 失败"
        FAIL=$((FAIL + 1))
    fi

    echo ""
    echo "结果: $PASS 通过, $FAIL 失败"
    if [ "$FAIL" -gt 0 ]; then
        echo "请检查安装日志排查失败项"
    else
        echo "所有检查通过，环境就绪！"
    fi
fi

echo ""
echo "========================================="
echo "  完成"
echo "========================================="
