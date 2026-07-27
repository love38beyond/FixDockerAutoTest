#!/usr/bin/env bash
# setup_fixgateway.sh — 搭建 FIX 网关容器（ctpfix）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

CONTAINER_NAME="ctpfix"
IMAGE_NAME="ctpfix:v1"
TAR_FILE="FIX.tar"

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
        --hostname=ctpfix_v1 \
        --network="$DOCKER_NETWORK" \
        -p 50001:50001 \
        -p 61111:61111 \
        "$IMAGE_NAME" \
        /usr/sbin/sshd -D
    log_success "容器 $CONTAINER_NAME 已启动"
    sleep 2
}

# --- 步骤 3：配置 setcap 以支持 ping ---
setup_setcap() {
    log_step "正在 $CONTAINER_NAME 容器内配置 ping 权限..."
    docker exec "$CONTAINER_NAME" bash -c '
        setcap cap_net_raw+ep /usr/bin/ping 2>/dev/null || \
        sudo setcap cap_net_raw+ep /usr/bin/ping 2>/dev/null || \
        echo "警告：setcap 可能执行失败，ping 命令可能无法正常使用"
    '
    log_success "setcap 配置完成"
}

# --- 步骤 4：修改 /etc/hosts 增加别名 ---
setup_hosts() {
    log_step "正在 $CONTAINER_NAME 容器内修改 /etc/hosts..."
    docker exec "$CONTAINER_NAME" bash -c '
        if grep -q "fixfront_mt1" /etc/hosts; then
            echo "hosts 别名已存在，跳过"
        else
            cat >> /etc/hosts << EOF
127.0.0.1 fixfront_mt1 fixfront_mt2 fixfront_md1 fixfront_md2 fixfront_md_se1 fixfront_mt_se1
EOF
            echo "已追加 hosts 别名"
        fi
    '
    log_success "hosts 别名已添加"
}

# --- 步骤 5：修改 FIX 网关 INI 配置文件 ---
setup_fix_config() {
    log_step "正在修改 $CONTAINER_NAME 容器内的 FIX 网关 INI 配置文件..."

    local ctptrade_ip
    ctptrade_ip=$(get_container_ip "ctptradefix")
    if [ -z "$ctptrade_ip" ]; then
        log_error "无法获取 ctptradefix 容器 IP，请确保 CTP 交易柜台容器已运行"
        exit 1
    fi
    log_info "CTP 交易柜台容器 IP：$ctptrade_ip"

    # 修复 libstdc++.so.6 软链接（GenMD5.sh 依赖）
    docker exec "$CONTAINER_NAME" bash -c '
        if [ -f /usr/lib64/libstdc++.so.6.0.19 ]; then
            rm -rf /usr/lib64/libstdc++.so.6
            ln -s /usr/lib64/libstdc++.so.6.0.19 /usr/lib64/libstdc++.so.6
            echo "已创建 libstdc++.so.6 软链接"
        fi
    '

    docker exec -i "$CONTAINER_NAME" su - fixf1 <<INNER
                export LD_LIBRARY_PATH="\$libdir:\${LD_LIBRARY_PATH:-}"
                break
            fi
        done
        ldconfig 2>/dev/null || true

        run_genmd5() {
            if [ -f "\$1" ]; then
                GenMD5.sh -g "\$1" || echo "警告: GenMD5.sh \$1 执行失败"
            fi
        }

        # 1. fixfront_mt.ini —— 替换 CTPfront1 中的 IP
        f1=~/fixfront_mt1/bin/fixfront_mt.ini
        if [ -f "\$f1" ]; then
            sed -i 's|\\(CTPfront1=tcp://\\)[0-9.]*\\(:11157\\)|\\1${ctptrade_ip}\\2|' "\$f1"
            echo "已更新 fixfront_mt.ini，CTPfront1 指向 ${ctptrade_ip}:11157"
            run_genmd5 "\$f1"
        else
            echo "警告：\$f1 不存在"
        fi

        # 2. fixfront_md.ini —— 替换 MDfront1 中的 IP（格式：tcp://:IP:port）
        f2=~/fixfront_md1/bin/fixfront_md.ini
        if [ -f "\$f2" ]; then
            sed -i 's|\\(MDfront1=tcp://:\\)[0-9.]*\\(:11167\\)|\\1${ctptrade_ip}\\2|' "\$f2"
            echo "已更新 fixfront_md.ini，MDfront1 指向 ${ctptrade_ip}:11167"
            run_genmd5 "\$f2"
        else
            echo "警告：\$f2 不存在"
        fi
INNER
    log_success "FIX 网关 INI 配置文件更新完成"
}

# --- 步骤 6：启动 FIX 网关服务 ---
start_fix_services() {
    log_step "正在启动 $CONTAINER_NAME 容器内的 FIX 网关服务..."
    docker exec "$CONTAINER_NAME" bash -c '
        printf "1\n" | script -q -c "su - fixf1 -c startall.sh" /dev/null || true
    '
    log_success "FIX 网关服务已启动"
}

# --- 主函数 ---
main() {
    log_info "========== 开始搭建 FIX 网关容器 =========="
    detect_host_ip
    setup_image
    setup_container
    setup_setcap
    setup_hosts
    setup_fix_config
    start_fix_services
    log_success "========== FIX 网关容器搭建完成 =========="
}

main "$@"
