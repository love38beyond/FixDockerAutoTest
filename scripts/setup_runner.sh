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

    # 挂载宿主机 FixAutoTest 目录到容器，更新代码无需重建镜像
    WORKDIR="/opt/fix-test/FixAutoTest/FixAutoTest"

    # 先启动容器保持后台运行
    docker run -d \
        --name="$CONTAINER_NAME" \
        --network="$DOCKER_NETWORK" \
        -e FIX_HOST="$RUNNER_HOST" \
        -e FIX_PORT="${FIX_PORT:-61111}" \
        -v "$FIXAUTO_DIR:$WORKDIR" \
        -v "$REPORT_DIR:/tmp/reports" \
        "$IMAGE_NAME" \
        tail -f /dev/null

    # 验证容器运行
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        log_error "容器 $CONTAINER_NAME 启动失败!"
        log_info "查看日志: docker logs $CONTAINER_NAME"
        exit 1
    fi
    log_info "容器 $CONTAINER_NAME 已启动 (代码挂载: $FIXAUTO_DIR → $WORKDIR)"

    # 将容器执行日志写入单独文件（避免二进制内容污染主日志 UTF-8 编码）
    RUNNER_LOG="${SCRIPT_DIR}/logs/runner_exec.log"

    # 在容器中执行测试
    log_info "开始在容器中执行测试..."
    docker exec "$CONTAINER_NAME" bash -c '
        WORKDIR="'"$WORKDIR"'"
        echo "[runner] 工作目录: $WORKDIR"
        cd "$WORKDIR" || { echo "[runner] 错误: 无法进入 $WORKDIR"; exit 1; }
        echo "[runner] 当前目录: $(pwd)"
        echo "[runner] 文件列表: $(ls FixInitiator.py tags.py generate_report.py 2>/dev/null)"
        echo "[runner] Python: $(python3 --version 2>&1 || echo NOT_FOUND)"
        echo "[runner] 环境 FIX_HOST=$FIX_HOST"
        rm -rf initiator/* 2>/dev/null || true
        echo "[runner] 开始执行测试..."
        python3 FixInitiator.py --host $FIX_HOST --reset-seqnums
        RET=$?
        echo "[runner] 测试完成, exit code=$RET"
        echo "[runner] CWD: $(pwd)"
        echo "[runner] syslog.txt: $(ls -la syslog.txt 2>/dev/null || echo 不存在)"
        echo "[runner] test_report.json: $(ls -la test_report.json 2>/dev/null || echo 不存在)"
        echo "[runner] 复制报告到 /tmp/reports/"
        for f in test_report.json test_report.html syslog.txt report.log; do
            TARGET="/tmp/reports/$f"
            if [ -f "$f" ]; then
                cp -v "$f" "$TARGET" 2>&1
            else
                echo "[runner] 跳过: $f (当前目录不存在)"
            fi
        done
        echo "[runner] /tmp/reports/ 内容: $(ls /tmp/reports/ 2>/dev/null || echo 空)"
    ' > "$RUNNER_LOG" 2>&1 || true
    # 只把关键行追加到主日志
    grep '\[runner\]' "$RUNNER_LOG" 2>/dev/null | while IFS= read -r line; do log_info "$line"; done || true

    # 兜底：如果容器没生成 HTML 但 JSON 存在，宿主机生成
    if [ -f "$REPORT_DIR/test_report.json" ] && [ ! -f "$REPORT_DIR/test_report.html" ]; then
        log_info "容器内未生成 HTML 报告，尝试宿主机生成..."
        RUNNER_PY="$SCRIPT_DIR/../FixAutoTest/FixAutoTest/generate_report.py"
        if [ -f "$RUNNER_PY" ]; then
            python3 "$RUNNER_PY" "$REPORT_DIR/test_report.json" "$REPORT_DIR/test_report.html" 2>/dev/null || true
        fi
    fi

    log_success "测试执行完成"
    log_info "报告目录: $REPORT_DIR"
    log_info "报告目录内容: $(ls -la "$REPORT_DIR" 2>/dev/null || echo 空)"
    if [ -f "$REPORT_DIR/test_report.html" ]; then
        log_info "HTML 报告: $REPORT_DIR/test_report.html"
    else
        log_info "警告: test_report.html 未生成"
    fi
    log_info "容器 $CONTAINER_NAME 已保留，可进入排查: docker exec -it $CONTAINER_NAME bash"
fi
