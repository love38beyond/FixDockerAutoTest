#!/usr/bin/env bash
# setup_exchange.sh — 搭建交易所容器（exchangefix）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

CONTAINER_NAME="exchangefix"
IMAGE_NAME="exchangefix:v1"
TAR_FILE="exchangeFIX.tar"

# --- 步骤 1：导入 Docker 镜像 ---
setup_image() {
    if image_exists "$IMAGE_NAME"; then
        log_info "镜像 $IMAGE_NAME 已存在，跳过导入"
        return 0
    fi
    if [ ! -f "$SCRIPT_DIR/$TAR_FILE" ]; then
        log_error "找不到 tar 文件：$SCRIPT_DIR/$TAR_FILE"
        exit 1
    fi
    log_step "正在从 $TAR_FILE 导入 Docker 镜像..."
    docker import "$SCRIPT_DIR/$TAR_FILE" "$IMAGE_NAME"
    log_success "镜像 $IMAGE_NAME 创建完成"
}

# --- 步骤 2：创建并启动容器 ---
setup_container() {
    if container_exists "$CONTAINER_NAME"; then
        log_info "容器 $CONTAINER_NAME 已存在，删除后重建..."
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm "$CONTAINER_NAME" 2>/dev/null || true
    fi
    log_step "正在创建并启动容器：$CONTAINER_NAME..."
    docker run -itd \
        --name="$CONTAINER_NAME" \
        --hostname=exchangefix_v1 \
        --network="$DOCKER_NETWORK" \
        -p 26171:26171 \
        -p 26181:26181 \
        "$IMAGE_NAME" \
        /usr/sbin/sshd -D
    log_success "容器 $CONTAINER_NAME 已启动"
    sleep 2
}

# --- 步骤 3：在容器内配置 SSH 密钥（root + trade2）---
setup_ssh() {
    log_step "正在 $CONTAINER_NAME 容器内配置 SSH 密钥..."
    docker exec "$CONTAINER_NAME" bash -c '
        # --- root 用户 ---
        rm -rf /root/.ssh
        mkdir -p /root/.ssh
        ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa -q
        cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
        cat > /root/.ssh/config << EOF
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
        chmod 600 /root/.ssh/config

        # --- trade2 用户（ecall.sh/confirmMainBackup.sh 需要）---
        rm -rf /home/trade2/.ssh
        mkdir -p /home/trade2/.ssh
        cp /root/.ssh/id_rsa /home/trade2/.ssh/
        cp /root/.ssh/id_rsa.pub /home/trade2/.ssh/
        cp /root/.ssh/authorized_keys /home/trade2/.ssh/
        cp /root/.ssh/config /home/trade2/.ssh/
        chmod 700 /home/trade2/.ssh
        chmod 600 /home/trade2/.ssh/id_rsa
        chmod 600 /home/trade2/.ssh/authorized_keys
        chmod 600 /home/trade2/.ssh/config
        chown -R trade2:trade2 /home/trade2/.ssh
    '
    log_success "SSH 密钥配置完成（root + trade2）"
}

# --- 步骤 4：配置 setcap 以支持 ping ---
setup_setcap() {
    log_step "正在 $CONTAINER_NAME 容器内配置 ping 权限..."
    docker exec "$CONTAINER_NAME" bash -c '
        setcap cap_net_raw+ep /usr/bin/ping 2>/dev/null || \
        sudo setcap cap_net_raw+ep /usr/bin/ping 2>/dev/null || \
        echo "警告：setcap 可能执行失败，ping 命令可能无法正常使用"
    '
    log_success "setcap 配置完成"
}

# --- 步骤 5：修改 service.list ---
setup_service_list() {
    log_step "正在修改 $CONTAINER_NAME 容器内的 service.list..."
    local target="/home/trade2/shell/console/service.list"
    # 获取本容器 IP（交易所服务自身地址）
    EXCHANGE_IP=$(get_container_ip "$CONTAINER_NAME")
    docker exec "$CONTAINER_NAME" bash -c "
        if [ -f $target ]; then
            sed -i 's/172\\.24\\.120\\.132/${EXCHANGE_IP}/g' $target
            echo '已将 service.list 中的 IP 更新为 ${EXCHANGE_IP}（容器自身 IP）'
        else
            echo '警告：在 $target 路径未找到 service.list'
        fi
    "
    log_success "service.list 更新完成"
}

# --- 步骤 6：修改 DeployConfig.PD.all.all.xml ---
setup_deploy_config() {
    log_step "正在修改 $CONTAINER_NAME 容器内的 DeployConfig.PD.all.all.xml..."
    local target="/home/trade2/cfg/config/DeployConfig.PD.all.all.xml"
    # 确保已获取容器 IP
    EXCHANGE_IP="${EXCHANGE_IP:-$(get_container_ip "$CONTAINER_NAME")}"
    EXCHANGE_BROADCAST=$(get_broadcast_ip "$EXCHANGE_IP")
    docker exec "$CONTAINER_NAME" bash -c "
        if [ -f $target ]; then
            # 将 172.24.120.132 替换为容器自身 IP（交易所服务绑定地址）
            sed -i 's/172\\.24\\.120\\.132/${EXCHANGE_IP}/g' $target
            # 将组播地址 172.24.120.255 替换为容器子网广播地址
            sed -i 's/172\\.24\\.120\\.255/${EXCHANGE_BROADCAST}/g' $target
            echo 'DeployConfig.PD.all.all.xml 更新完成（IP=${EXCHANGE_IP}, 广播=${EXCHANGE_BROADCAST}）'
        else
            echo '警告：在 $target 路径未找到 DeployConfig.PD.all.all.xml'
        fi
    "
    log_success "DeployConfig.PD.all.all.xml 更新完成"
}

# --- 步骤 7：发布配置并启动交易所服务 ---
start_exchange_services() {
    log_step "正在启动 $CONTAINER_NAME 容器内的交易所服务..."
    docker exec "$CONTAINER_NAME" bash -c '
        # 切换到 trade2 用户执行命令
        su - trade2 -c "ecall.sh admin 1 copyBaseConfig"
        su - trade2 -c "ecall.sh admin 1 startService"
        # confirmMainBackup — 自动确认输入 y
        echo "y" | su - trade2 -c "confirmMainBackup.sh admin 1"
    '
    log_success "交易所服务已启动"
}

# --- 主函数 ---
main() {
    log_info "========== 开始搭建交易所容器 =========="
    detect_host_ip
    setup_image
    setup_container
    setup_ssh
    setup_setcap
    setup_service_list
    setup_deploy_config
    start_exchange_services
    log_success "========== 交易所容器搭建完成 =========="
}

main "$@"
