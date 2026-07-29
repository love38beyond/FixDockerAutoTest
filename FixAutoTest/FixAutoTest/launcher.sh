#!/bin/bash
# Wrapper script for FixInitiator.py with Docker-friendly environment variable support.
# Run with: FIX_HOST=192.168.1.100 bash launcher.sh
export FIX_HOST="${FIX_HOST:-10.3.138.139}"
export FIX_PORT="${FIX_PORT:-61111}"

# 切换到脚本所在目录（支持符号链接和相对路径调用）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 验证目录正确性
if [ ! -f "FixInitiator.py" ]; then
    echo "错误: 未找到 FixInitiator.py，请从脚本所在目录运行"
    echo "  当前: $(pwd)"
    echo "  预期: <path>/FixAutoTest/FixAutoTest/"
    exit 1
fi

PYTHON=$(command -v python3.6 || command -v python36 || command -v python3 || command -v python)
$PYTHON FixInitiator.py "$@"
