#!/usr/bin/env bash
# common.sh — Docker 测试环境搭建公共函数库
set -euo pipefail

# --- 颜色输出 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# --- Docker 网络 ---
DOCKER_NETWORK="fix-test-net"

# --- 全局变量 ---
HOST_IP=""           # 宿主机 IP（FixAutoTest 连接 FIX 网关用）
EXCHANGE_IP=""       # 交易所容器 IP
CTPTRADE_IP=""       # CTP 交易柜台容器 IP
FIXGATEWAY_IP=""     # FIX 网关容器 IP
EXCHANGE_BROADCAST=""  # 交易所容器子网广播地址
CTPTRADE_BROADCAST=""  # CTP 容器子网广播地址

# --- 日志文件 ---
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${_COMMON_DIR}/logs"
LOG_FILE=""

_init_log() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="${LOG_DIR}/env_setup_${timestamp}.log"
    export LOG_FILE
    mkdir -p "$LOG_DIR"
    echo "========== 开始时间: $(date '+%Y-%m-%d %H:%M:%S') ==========" > "$LOG_FILE"
    echo "日志文件: $LOG_FILE"
}

log_info()    { echo -e "${BLUE}[信息]${NC}  $(date '+%H:%M:%S') $*"; { [ -n "$LOG_FILE" ] && echo "[信息]  $(date '+%H:%M:%S') $*" >> "$LOG_FILE"; } || true; }
log_error()   { echo -e "${RED}[错误]${NC} $(date '+%H:%M:%S') $*"; { [ -n "$LOG_FILE" ] && echo "[错误] $(date '+%H:%M:%S') $*" >> "$LOG_FILE"; } || true; }
log_success() { echo -e "${GREEN}[完成]${NC}  $(date '+%H:%M:%S') $*"; { [ -n "$LOG_FILE" ] && echo "[完成]  $(date '+%H:%M:%S') $*" >> "$LOG_FILE"; } || true; }
log_step()    { echo -e "${YELLOW}[步骤]${NC}  $(date '+%H:%M:%S') $*"; { [ -n "$LOG_FILE" ] && echo "[步骤]  $(date '+%H:%M:%S') $*" >> "$LOG_FILE"; } || true; }

# --- 检测宿主机 IP ---
detect_host_ip() {
    # 环境变量优先
    if [ -n "${HOST_IP:-}" ]; then
        log_info "使用环境变量 HOST_IP：$HOST_IP"
        return 0
    fi
    # 方式 1: ip addr 获取 global scope IPv4 地址
    if command -v ip &>/dev/null; then
        HOST_IP=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
        # 方式 2: 通过默认路由接口获取
        if [ -z "$HOST_IP" ]; then
            HOST_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || true)
        fi
    fi
    # 方式 3: hostname -I
    if [ -z "$HOST_IP" ] && command -v hostname &>/dev/null; then
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$HOST_IP" ]; then
        log_error "无法自动检测宿主机 IP，请设置环境变量: export HOST_IP=<宿主机IP>"
        return 0
    fi
    log_info "检测到宿主机 IP：$HOST_IP"
}

# --- Docker 辅助函数 ---
container_exists() {
    docker container inspect "$1" &>/dev/null
}

image_exists() {
    docker image inspect "$1" &>/dev/null
}

network_exists() {
    docker network inspect "$1" &>/dev/null
}

# --- 获取容器在 Docker 网络上的 IP ---
get_container_ip() {
    local container_name="$1"
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name"
}

# --- 基于容器 IP 计算 /24 子网广播地址 ---
get_broadcast_ip() {
    local container_ip="$1"
    echo "$container_ip" | sed 's/[0-9]*$/255/'
}

# --- 在容器内执行命令 ---
ensure_docker_exec() {
    local container="$1"
    local cmd="$2"
    docker exec "$container" bash -c "$cmd"
}
