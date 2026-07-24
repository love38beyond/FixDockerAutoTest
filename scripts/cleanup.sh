#!/usr/bin/env bash
# cleanup.sh — 拆除 FIX 测试环境
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

CONTAINERS=("ctpfix" "ctptradefix" "exchangefix")
REMOVE_IMAGES=false

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --images) REMOVE_IMAGES=true; shift;;
        -h|--help)
            echo "用法：$0 [--images]"
            echo "  --images  同时删除 Docker 镜像"
            exit 0
            ;;
        *) shift;;
    esac
done

main() {
    echo "正在清理 FIX 测试环境..."

    # 按相反顺序停止并移除容器（FIX → CTP → 交易所）
    for container in "${CONTAINERS[@]}"; do
        if container_exists "$container"; then
            log_step "正在停止并移除 $container..."
            docker stop "$container" 2>/dev/null || true
            docker rm "$container" 2>/dev/null || true
            log_success "$container 已移除"
        else
            log_info "$container 不存在，跳过"
        fi
    done

    # 移除网络
    if network_exists "$DOCKER_NETWORK"; then
        log_step "正在移除网络 $DOCKER_NETWORK..."
        docker network rm "$DOCKER_NETWORK" 2>/dev/null || true
        log_success "网络 $DOCKER_NETWORK 已移除"
    fi

    # 可选：移除镜像
    if [ "$REMOVE_IMAGES" = true ]; then
        for image in "exchangefix:v1" "ctptradefix:v2" "ctpfix:v1"; do
            if image_exists "$image"; then
                log_step "正在删除镜像 $image..."
                docker rmi "$image" 2>/dev/null || true
                log_success "镜像 $image 已删除"
            fi
        done
    fi

    log_success "清理完成"
}

main "$@"
