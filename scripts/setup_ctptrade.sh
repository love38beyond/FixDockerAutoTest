#!/usr/bin/env bash
# setup_ctptrade.sh — 搭建 CTP 交易柜台容器（ctptradefix）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

CONTAINER_NAME="ctptradefix"
IMAGE_NAME="ctptradefix:v2"
TAR_FILE="CtpTradeFIX.tar"

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
        log_info "容器 $CONTAINER_NAME 已存在"
        if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
            log_step "正在启动已有容器 $CONTAINER_NAME..."
            docker start "$CONTAINER_NAME"
            sleep 3
        fi
        return 0
    fi
    log_step "正在创建并启动容器：$CONTAINER_NAME..."
    docker run -itd \
        --name="$CONTAINER_NAME" \
        --hostname=ctptradefix_v1 \
        --network="$DOCKER_NETWORK" \
        -p 11157:11157 \
        -p 11167:11167 \
        -p 11155:11155 \
        "$IMAGE_NAME" \
        /usr/sbin/sshd -D
    log_success "容器 $CONTAINER_NAME 已启动"
    sleep 2
}

# --- 步骤 3：配置 SSH 密钥（trade1 用户） ---
setup_ssh() {
    log_step "正在 $CONTAINER_NAME 容器内配置 SSH 密钥..."
    if docker exec "$CONTAINER_NAME" test -f /home/trade1/.ssh/authorized_keys 2>/dev/null; then
        log_info "SSH 密钥已配置，跳过"
        return 0
    fi
    docker exec "$CONTAINER_NAME" bash -c '
        mkdir -p /home/trade1/.ssh
        ssh-keygen -t rsa -N "" -f /home/trade1/.ssh/id_rsa -q
        cp /home/trade1/.ssh/id_rsa.pub /home/trade1/.ssh/authorized_keys
        chmod 700 /home/trade1/.ssh
        chmod 600 /home/trade1/.ssh/authorized_keys
        chown -R trade1:trade1 /home/trade1/.ssh
    '
    log_success "SSH 密钥配置完成"
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

# --- 步骤 5：修改 /etc/hosts 增加别名 ---
setup_hosts() {
    log_step "正在 $CONTAINER_NAME 容器内修改 /etc/hosts..."
    docker exec "$CONTAINER_NAME" bash -c '
        if grep -q "compositor1" /etc/hosts; then
            echo "hosts 别名已存在，跳过"
        else
            sed -i "/^127\.0\.0\.1[[:space:]]/ s/$/ compositor1 arb okernel1 tkernel1 qkernel1 dbmt tmdb tinit drmt front1 front2 front3 front4 offermanager1 shfeoffer1 shfemdserver1 front_se5 front_md_se6 dbmt_se zceoffer1 zcemdserver1 cffexoffer1 ffexmdserver1 ineoffer1 inemdserver1 ineoffer2 inemdserver2 cfmmcoffer1 cfmmcoffermanager1 cffexotcoffer front_se100/" /etc/hosts
            echo "已追加 hosts 别名"
        fi
    '
    log_success "hosts 别名已添加"
}

# --- 步骤 6：修改 INI 文件中的交易所地址 ---
setup_ini_files() {
    log_step "正在修改 $CONTAINER_NAME 容器内的 INI 配置文件..."
    local exchange_ip
    exchange_ip=$(get_container_ip "exchangefix")
    if [ -z "$exchange_ip" ]; then
        log_error "无法获取 exchangefix 容器 IP，请确保交易所容器已运行"
        exit 1
    fi
    log_info "交易所容器 IP：$exchange_ip"

    docker exec "$CONTAINER_NAME" su - trade1 -c "
        # 1. ineoffer.ini —— 替换 ExchangeAddress 中的 IP
        f1=~/ineoffer2/bin/ineoffer.ini
        if [ -f \"\$f1\" ]; then
            sed -i 's|\\(ExchangeAddress=tcp://\\)[0-9.]*\\(:26181\\)|\\1${exchange_ip}\\2|' \"\$f1\"
            echo \"已更新 ineoffer.ini，ExchangeAddress 指向 ${exchange_ip}:26181\"
            GenMD5.sh -g \"\$f1\"
        else
            echo \"警告：\$f1 不存在\"
        fi

        # 2. inemdserver.ini —— 替换 FrontAddr 中的 IP
        f2=~/inemdserver2/bin/inemdserver.ini
        if [ -f \"\$f2\" ]; then
            sed -i 's|\\(FrontAddr=tcp://\\)[0-9.]*\\(:26171\\)|\\1${exchange_ip}\\2|' \"\$f2\"
            echo \"已更新 inemdserver.ini，FrontAddr 指向 ${exchange_ip}:26171\"
            GenMD5.sh -g \"\$f2\"
        else
            echo \"警告：\$f2 不存在\"
        fi

        # 3. shfeoffer.ini —— 替换 ExchangeAddress 中的 IP
        f3=~/shfeoffer1/bin/shfeoffer.ini
        if [ -f \"\$f3\" ]; then
            sed -i 's|\\(ExchangeAddress=tcp://\\)[0-9.]*\\(:26181\\)|\\1${exchange_ip}\\2|' \"\$f3\"
            echo \"已更新 shfeoffer.ini，ExchangeAddress 指向 ${exchange_ip}:26181\"
            GenMD5.sh -g \"\$f3\"
        else
            echo \"警告：\$f3 不存在\"
        fi

        # 4. shfemdserver.ini —— 替换 FrontAddr 中的 IP
        f4=~/shfemdserver1/bin/shfemdserver.ini
        if [ -f \"\$f4\" ]; then
            sed -i 's|\\(FrontAddr=tcp://\\)[0-9.]*\\(:26171\\)|\\1${exchange_ip}\\2|' \"\$f4\"
            echo \"已更新 shfemdserver.ini，FrontAddr 指向 ${exchange_ip}:26171\"
            GenMD5.sh -g \"\$f4\"
        else
            echo \"警告：\$f4 不存在\"
        fi
    "
    log_success "INI 配置文件更新完成"
}

# --- 步骤 7：修改 DeployConfig.xml 并发布 ---
setup_deploy_config() {
    log_step "正在修改 $CONTAINER_NAME 容器内的 DeployConfig.xml..."
    local target="/home/trade1/cfg/config/DeployConfig.xml"
    local ctp_ip
    ctp_ip=$(get_container_ip "$CONTAINER_NAME")
    local broadcast_ip
    broadcast_ip=$(get_broadcast_ip "$ctp_ip")

    docker exec "$CONTAINER_NAME" bash -c "
        if [ -f $target ]; then
            sed -i 's/10\\.3\\.138\\.191/${broadcast_ip}/g' $target
            echo \"DeployConfig.xml 更新完成，组播地址替换为 ${broadcast_ip}\"
        else
            echo \"警告：$target 不存在\"
        fi
    "
    log_success "DeployConfig.xml 更新完成"

    # 切换到 trade1 用户执行 cpall.sh 发布配置
    log_step "正在发布 DeployConfig.xml 配置..."
    docker exec "$CONTAINER_NAME" bash -c '
        su - trade1 -c "cpall.sh"
    '
    log_success "DeployConfig.xml 配置已发布"
}

# --- 步骤 8：启动 CTP 交易系统 ---
start_ctptrade_services() {
    log_step "正在启动 $CONTAINER_NAME 容器内的 CTP 交易系统..."
    docker exec "$CONTAINER_NAME" bash -c '
        echo "1" | su - trade1 -c "startall.sh"
    '
    log_success "CTP 交易系统已启动"
}

# --- 主函数 ---
main() {
    log_info "========== 开始搭建 CTP 交易柜台容器 =========="
    detect_host_ip
    setup_image
    setup_container
    setup_ssh
    setup_setcap
    setup_hosts
    setup_ini_files
    setup_deploy_config
    start_ctptrade_services
    log_success "========== CTP 交易柜台容器搭建完成 =========="
}

main "$@"
