#!/usr/bin/env bash
# setup_runner.sh — 构建 fix-runner 镜像 + 运行自动化测试
# 用法: bash setup_runner.sh [--build-only|--run-only] [--host HOST_IP]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

IMAGE_NAME="fix-runner:latest"
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
        *) shift ;;
    esac
done

if [ -z "$RUNNER_HOST" ]; then
    detect_host_ip
    RUNNER_HOST="$HOST_IP"
fi

# ---- 构建镜像 ----
if [ "$BUILD" = true ]; then
    log_step "正在构建 fix-runner Docker 镜像..."
    if [ ! -d "$FIXAUTO_DIR" ]; then
        log_error "找不到 FixAutoTest 目录: $FIXAUTO_DIR"
        exit 1
    fi
    docker build -t "$IMAGE_NAME" -f "$FIXAUTO_DIR/Dockerfile" "$FIXAUTO_DIR"
    log_success "镜像 $IMAGE_NAME 构建完成"
fi

# ---- 运行测试 ----
if [ "$RUN" = true ]; then
    log_step "正在启动 fix-runner 容器执行测试..."

    if container_exists "$CONTAINER_NAME"; then
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    fi

    REPORT_DIR="${SCRIPT_DIR}/logs/reports"
    mkdir -p "$REPORT_DIR"

    docker run --rm \
        --name="$CONTAINER_NAME" \
        --network="$DOCKER_NETWORK" \
        -e FIX_HOST="$RUNNER_HOST" \
        -e FIX_PORT="${FIX_PORT:-61111}" \
        -v "$REPORT_DIR:/opt/fix-test/output" \
        "$IMAGE_NAME" \
        bash -c "
            cd /opt/fix-test
            rm -rf initiator/* 2>/dev/null || true
            python3 FixInitiator.py --host \$FIX_HOST --reset-seqnums
            cp test_report.json test_report.html syslog.txt report.log /opt/fix-test/output/ 2>/dev/null || true
        " || true

    log_success "测试执行完成"
    log_info "报告保存在: $REPORT_DIR"
    if [ -f "$REPORT_DIR/test_report.html" ]; then
        log_info "HTML 报告: $REPORT_DIR/test_report.html"
    fi
fi
