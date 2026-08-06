#!/usr/bin/env bash
# env_setup.sh — FIX Docker 测试环境主编排脚本
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# --- 配置 ---
REQUIRED_TARS=("exchangeFIX.tar" "CtpTradeFIX.tar" "FIX.tar")
REQUIRED_CMDS=("docker" "expect")

# --- 前置条件检查 ---
check_prerequisites() {
    log_step "正在检查前置条件..."

    # 检查 Docker 守护进程
    if ! docker info &>/dev/null; then
        log_error "Docker 守护进程未运行，请先启动 Docker。"
        exit 1
    fi
    log_info "Docker 守护进程：正常"

    # 检查必需命令
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "缺少必需命令：$cmd，请先安装。"
            exit 1
        fi
        log_info "$cmd：正常"
    done

    # 检查 tar 文件是否存在
    for tar in "${REQUIRED_TARS[@]}"; do
        if [ ! -f "$SCRIPT_DIR/$tar" ]; then
            log_error "找不到必需文件：$SCRIPT_DIR/$tar"
            log_error "请将 tar 镜像文件放置到 scripts/ 目录下"
            exit 1
        fi
        log_info "$tar：已找到"
    done

    log_success "所有前置条件检查通过"
}

# --- 创建 Docker 网络 ---
setup_network() {
    if network_exists "$DOCKER_NETWORK"; then
        log_info "Docker 网络 $DOCKER_NETWORK 已存在"
        return 0
    fi
    log_step "正在创建 Docker 桥接网络：$DOCKER_NETWORK..."
    docker network create --driver bridge "$DOCKER_NETWORK"
    log_success "网络 $DOCKER_NETWORK 创建完成"
}

# --- 主函数 ---
main() {
    echo ""
    echo "============================================"
    echo "  FIX Docker 测试环境搭建"
    echo "============================================"
    echo ""

    _init_log
    detect_host_ip

    # 阶段 0：前置条件
    check_prerequisites
    setup_network

    # 阶段 1：交易所（必须最先启动——CTP 依赖交易所）
    log_info "=== 阶段 1/3：交易所容器 ==="
    bash "$SCRIPT_DIR/setup_exchange.sh"
    # 获取交易所容器 IP，供后续阶段使用
    export EXCHANGE_IP=$(get_container_ip "exchangefix")
    export EXCHANGE_BROADCAST=$(get_broadcast_ip "$EXCHANGE_IP")
    log_info "交易所容器 IP：$EXCHANGE_IP，广播地址：$EXCHANGE_BROADCAST"

    # 阶段 2：CTP 交易柜台（依赖交易所已运行，需要 EXCHANGE_IP 连接交易所）
    log_info "=== 阶段 2/3：CTP 交易柜台容器 ==="
    bash "$SCRIPT_DIR/setup_ctptrade.sh"
    # 获取 CTP 容器 IP，供后续阶段使用
    export CTPTRADE_IP=$(get_container_ip "ctptradefix")
    export CTPTRADE_BROADCAST=$(get_broadcast_ip "$CTPTRADE_IP")
    log_info "CTP 容器 IP：$CTPTRADE_IP，广播地址：$CTPTRADE_BROADCAST"

    # 阶段 3：FIX 网关（依赖 CTP 已运行，需要 CTPTRADE_IP 连接 CTP）
    log_info "=== 阶段 3/4：FIX 网关容器 ==="
    bash "$SCRIPT_DIR/setup_fixgateway.sh"
    export FIXGATEWAY_IP=$(get_container_ip "ctpfix")

    # 阶段 4：构建 fix-runner 镜像 + 运行自动化测试（可选）
    if [ "${SKIP_RUNNER:-false}" != true ]; then
        log_info "=== 阶段 4/4：构建测试运行镜像 ==="
        if [ -d "$SCRIPT_DIR/../FixAutoTest/FixAutoTest" ]; then
            bash "$SCRIPT_DIR/setup_runner.sh" --build --host "$HOST_IP" || log_info "测试运行镜像构建/执行跳过（可稍后手动运行）"
        else
            log_info "未找到 FixAutoTest 目录，跳过阶段 4"
        fi
    else
        log_info "=== 阶段 4/4：已跳过（SKIP_RUNNER=true）==="
    fi

    # 汇总信息（同时输出到终端和日志）
    summary() { echo -e "$*"; echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"; }
    HR="──────────────────────────────────────────────────────────"

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║        FIX Docker 测试环境 — 部署完成                   ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    { echo "╔══════════════════════════════════════════════════════════╗"
      echo "║        FIX Docker 测试环境 — 部署完成                   ║"
      echo "╚══════════════════════════════════════════════════════════╝"
      echo ""; } | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"

    # ── 容器状态 ──
    summary "${GREEN}${HR}${NC}"
    summary "${GREEN}  容器状态${NC}"
    summary "${GREEN}${HR}${NC}"
    docker ps -a --format '{{.Names}} {{.Status}} {{.Ports}}' 2>/dev/null | grep -E 'exchangefix|ctptradefix|ctpfix|fix-runner' | while read line; do
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2, $3, $4, $5}')
        summary "  ${name}    ${status}"
    done

    # ── 网络信息 ──
    summary ""
    summary "${GREEN}${HR}${NC}"
    summary "${GREEN}  网络信息${NC}"
    summary "${GREEN}${HR}${NC}"
    summary "  宿主机 IP:     ${HOST_IP}"
    summary "  Docker 网络:   ${DOCKER_NETWORK}"
    summary ""
    summary "  容器 IP:"
    summary "    交易所:      ${EXCHANGE_IP:-N/A}"
    summary "    CTP 柜台:    ${CTPTRADE_IP:-N/A}"
    summary "    FIX 网关:    ${FIXGATEWAY_IP:-N/A}"
    RUNNER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' fix-runner 2>/dev/null || echo "")
    [ -n "$RUNNER_IP" ] && summary "    fix-runner:  ${RUNNER_IP}"

    # ── 连接地址 ──
    summary ""
    summary "${GREEN}${HR}${NC}"
    summary "${GREEN}  连接地址${NC}"
    summary "${GREEN}${HR}${NC}"
    summary "  FIX 交易:     tcp://${HOST_IP}:61111"
    summary "  FIX 行情:     tcp://${HOST_IP}:50001"
    summary "  ticlient:     ${HOST_IP}:11155"
    summary "                (0000_admin / 1 / 1)"

    # ── 测试报告 ──
    if [ "${SKIP_RUNNER:-false}" != true ]; then
        REPORT_DIR="${SCRIPT_DIR}/logs/reports"
        summary ""
        summary "${GREEN}${HR}${NC}"
        summary "${GREEN}  测试报告${NC}"
        summary "${GREEN}${HR}${NC}"
        if [ -f "$REPORT_DIR/test_report.html" ]; then
            summary "  HTML 报告:    $REPORT_DIR/test_report.html"
        fi
        if [ -f "$REPORT_DIR/test_report.json" ]; then
            summary "  JSON 报告:    $REPORT_DIR/test_report.json"
        fi
        summary "  报告目录:     $REPORT_DIR"
    fi

    # ── 日志文件 ──
    summary ""
    summary "${GREEN}${HR}${NC}"
    summary "${GREEN}  日志文件${NC}"
    summary "${GREEN}${HR}${NC}"
    summary "  部署日志:     $LOG_FILE"

    summary ""
    summary "╔══════════════════════════════════════════════════════════╗"
    summary "║  初始化 CTP 柜台: ticlient ${HOST_IP}:11155            ║"
    summary "║  用户: 0000_admin  部门: 1  密码: 1                    ║"
    summary "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

main "$@"
