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
    # 优先尝试从预构建 tar 加载（离线场景），多路径搜索
    RUNNER_TAR=""
    for candidate in \
        "$SCRIPT_DIR/fix-runner.tar" \
        "$FIXAUTO_DIR/softpackage/fix-runner.tar" \
        "$FIXAUTO_DIR/fix-runner.tar" \
        "$(pwd)/fix-runner.tar"; do
        if [ -f "$candidate" ]; then
            RUNNER_TAR="$candidate"
            break
        fi
    done

    if [ -n "$RUNNER_TAR" ]; then
        log_info "从预构建包加载: $RUNNER_TAR"
        docker load -i "$RUNNER_TAR" || docker import "$RUNNER_TAR" "$IMAGE_NAME" || true
        log_success "镜像 $IMAGE_NAME 加载完成"
    elif docker image inspect "$IMAGE_NAME" &>/dev/null; then
        log_info "镜像 $IMAGE_NAME 已存在，跳过构建"
    elif [ -f "$FIXAUTO_DIR/Dockerfile" ]; then
        log_info "从 Dockerfile 构建镜像..."
        docker build -t "$IMAGE_NAME" -f "$FIXAUTO_DIR/Dockerfile" "$FIXAUTO_DIR"
        log_success "镜像 $IMAGE_NAME 构建完成"
    else
        log_error "找不到 fix-runner.tar 或 Dockerfile"
        log_error "搜索路径: $SCRIPT_DIR/fix-runner.tar, $FIXAUTO_DIR/softpackage/fix-runner.tar"
        exit 1
    fi
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
