#!/usr/bin/env bash
# setup_runner.sh — 构建 fix-runner 镜像 + 运行自动化测试
# 用法: bash setup_runner.sh [--build-only|--run-only] [--host HOST_IP]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

IMAGE_NAME="fix-runner:v1"
CONTAINER_NAME="fix-runner"
FIXAUTO_DIR="$SCRIPT_DIR/../FixAutoTest/FixAutoTest"

BUILD=true
RUN=true
RUNNER_HOST="${HOST_IP:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-only) BUILD=true; RUN=false; shift ;;
        --run-only) BUILD=false; RUN=true; shift ;;
        --host) RUNNER_HOST="$2"; shift 2 ;;
        -y|--yes) AUTO_YES=true; shift ;;
        *) shift ;;
    esac
done

if [ -z "$RUNNER_HOST" ]; then
    detect_host_ip
    RUNNER_HOST="$HOST_IP"
fi

# ---- 构建镜像 ----
if [ "$BUILD" = true ]; then
    log_step "正在准备 fix-runner Docker 镜像..."
    RUNNER_TAR="$SCRIPT_DIR/fix-runner.tar"
    if image_exists "$IMAGE_NAME"; then
        log_info "镜像 $IMAGE_NAME 已存在，跳过导入"
    elif [ -f "$RUNNER_TAR" ]; then
        docker import "$RUNNER_TAR" "$IMAGE_NAME"
        log_success "镜像 $IMAGE_NAME 导入完成"
    else
        log_error "找不到 $RUNNER_TAR"
        log_error "请先将 fix-runner.tar 放到 scripts/ 目录下"
        exit 1
    fi
fi

# ---- 运行测试 ----
if [ "$RUN" = true ]; then
    # 交互式提示：先初始化 ticlient
    if [ "${AUTO_YES:-false}" != true ]; then
        echo ""
        echo "========================================="
        echo "  请先用 ticlient 初始化 CTP 交易系统"
        echo "  IP: $RUNNER_HOST  端口: 11155"
        echo "  用户名: 0000_admin  部门: 1  密码: 1"
        echo "========================================="
        read -p "  完成后按 Enter 键继续..."
        echo ""
    fi

    log_step "正在启动 fix-runner 容器执行测试..."

    if container_exists "$CONTAINER_NAME"; then
        log_info "容器 $CONTAINER_NAME 已存在，先删除..."
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    fi

    REPORT_DIR="${SCRIPT_DIR}/logs/reports"
    mkdir -p "$REPORT_DIR"

    # 先启动容器保持后台运行
    docker run -d \
        --name="$CONTAINER_NAME" \
        --network="$DOCKER_NETWORK" \
        -e FIX_HOST="$RUNNER_HOST" \
        -e FIX_PORT="${FIX_PORT:-61111}" \
        -v "$REPORT_DIR:/tmp/reports" \
        "$IMAGE_NAME" \
        tail -f /dev/null

    # 在容器中执行测试
    docker exec "$CONTAINER_NAME" bash -c '
        # 自动查找 FixInitiator.py 所在目录
        WORKDIR=$(find /opt -name "FixInitiator.py" -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "")
        if [ -z "$WORKDIR" ]; then
            WORKDIR=$(find / -name "FixInitiator.py" -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "")
        fi
        if [ -z "$WORKDIR" ]; then
            echo "错误: 找不到 FixInitiator.py"
            exit 1
        fi
        cd "$WORKDIR"
        rm -rf initiator/* 2>/dev/null || true
        python3 FixInitiator.py --host $FIX_HOST --reset-seqnums
        cp test_report.json test_report.html syslog.txt report.log /tmp/reports/ 2>/dev/null || true
    ' || true

    log_success "测试执行完成"
    log_info "报告保存在: $REPORT_DIR"
    if [ -f "$REPORT_DIR/test_report.html" ]; then
        log_info "HTML 报告: $REPORT_DIR/test_report.html"
    fi
    log_info "容器 $CONTAINER_NAME 已保留，可进入排查: docker exec -it $CONTAINER_NAME bash"
fi
