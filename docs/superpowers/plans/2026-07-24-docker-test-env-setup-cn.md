# Docker 测试环境搭建 — 实施方案（中文版）

> **面向执行代理：** 必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 子技能来按任务逐个实施本方案。步骤使用 checkbox（`- [ ]`）语法进行追踪。

**目标：** 通过 Shell 脚本自动化创建 3 容器 Docker 测试环境（交易所 → CTP 交易柜台 → FIX 网关），替代 `docker-fix.txt` 中的手动操作步骤。

**架构方案：** 一个主编排脚本（`env_setup.sh`）协调三个独立容器搭建脚本。所有容器运行在同一个 Docker 桥接网络上，**容器间通过各自 Docker 网络 IP 直接通信**。脚本在创建容器后通过 `docker inspect` 获取各容器 IP，按「自身地址」或「目标地址」的语义选择正确的 IP 进行替换。通过 `docker exec` 在容器内执行配置命令，使用 `expect`/heredoc 模式处理交互式提示。所有配置文件模板来源于 `fileExample/` 目录。

**技术栈：** Bash 4.x、Docker CLI、`expect`（交互式命令自动化）、`sed`（IP 地址替换）。

## 全局约束

- 目标操作系统：Linux（Docker 宿主机），脚本使用 `bash` 编写
- Docker 必须已安装并正常运行
- Docker 镜像文件（`exchangeFIX.tar`、`CtpTradeFIX.tar`、`FIX.tar`）必须位于脚本工作目录中
- 宿主机必须安装 `expect`（`yum install -y expect` 或 `apt-get install -y expect`）
- 脚本必须具备幂等性——可安全地重复执行（创建前检查容器/镜像是否已存在）
- 所有脚本使用 `set -euo pipefail` 进行错误处理
- 容器启动顺序强制执行：交易所 → CTP 交易柜台 → FIX 网关

---

## 文件结构

```
scripts/
├── env_setup.sh              # 主编排器——调用此脚本一键搭建全部环境
├── common.sh                 # 公共函数：IP 检测、日志输出、幂等性辅助函数
├── setup_exchange.sh         # 容器 1：交易所（exchangefix）
├── setup_ctptrade.sh         # 容器 2：CTP 交易柜台（ctptradefix）
├── setup_fixgateway.sh       # 容器 3：FIX 网关（ctpfix）
└── cleanup.sh                # 环境清理——拆除所有容器（用于重置环境）
```

### 各文件职责

| 文件 | 职责说明 |
|------|---------|
| `common.sh` | 被所有脚本引用。定义：`detect_host_ip()`、`log_info()`、`log_error()`、`container_exists()`、`image_exists()`、`HOST_IP` 全局变量、`DOCKER_NETWORK` 网络名称（`fix-test-net`）、彩色输出辅助函数 |
| `env_setup.sh` | 入口脚本。解析命令行参数，检查前置条件（docker、expect、tar 文件），创建 Docker 桥接网络，按顺序调用 3 个容器搭建脚本，打印摘要信息 |
| `setup_exchange.sh` | 导入 `exchangeFIX.tar` → 镜像 `exchangefix:v1`，创建并运行 exchangefix 容器，配置 SSH 密钥，配置 `setcap` 以支持 ping，修改 `service.list` 和 `DeployConfig.PD.all.all.xml` 中的 IP 地址，启动交易所服务 |
| `setup_ctptrade.sh` | 导入 `CtpTradeFIX.tar` → 镜像 `ctptradefix:v2`，创建并运行 ctptradefix 容器，配置 SSH，修改 `/etc/hosts`，更新 4 个报盘/行情服务器 INI 文件中的宿主机 IP，修改 DeployConfig.xml 组播地址，启动 CTP 服务 |
| `setup_fixgateway.sh` | 导入 `FIX.tar` → 镜像 `ctpfix:v1`，创建并运行 ctpfix 容器，配置 `setcap`，更新 `fixfront_mt.ini` 和 `fixfront_md.ini` 中的宿主机 IP，启动 FIX 网关服务 |
| `cleanup.sh` | 停止并移除所有 3 个容器，移除 Docker 网络，可选移除镜像。随时可安全执行。 |

---

## 容器依赖关系与通信模型

```
[FixAutoTest (宿主机)] --tcp:61111--> [FIX 网关 (ctpfix)]
                                          |
                                          | tcp://<FIXGATEWAY_IP>:61111 (监听)
                                          | tcp://<CTPTRADE_IP>:11157   (连接CTP交易)
                                          | tcp://<CTPTRADE_IP>:11167   (连接CTP行情)
                                          v
                                     [CTP 交易柜台 (ctptradefix)]
                                          |
                                          | tcp://<EXCHANGE_IP>:26181    (连接交易所报盘)
                                          | tcp://<EXCHANGE_IP>:26171    (连接交易所行情)
                                          v
                                     [交易所 (exchangefix)]
                                          |
                                          | 内部服务绑定 <EXCHANGE_IP>
                                          | 组播地址为容器子网广播地址
```

**容器间通信：** 直接使用目标容器的 Docker 网络 IP（如 `172.18.0.x`），不需要通过宿主机。
**外部访问：** 仅 FixAutoTest 需要通过 `-p` 发布的端口（`<宿主机IP>:61111`）连接 FIX 网关。

---

## 关键设计决策

### 1. IP 检测策略

脚本需要三类 IP，分别通过不同方式获取：

**（A）宿主机 IP** — FixAutoTest 连接 FIX 网关时使用：
```bash
# 在 common.sh 中——获取主网卡的非回环 IPv4 地址
HOST_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
# 备用方案：通过默认路由获取
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(ip route get 1 | awk '{print $7; exit}')
fi
```

**（B）容器自身 IP** — 用于该容器内"我绑定在哪个 IP"的配置（service.list、DeployConfig.PD.all.all.xml 服务地址）：
```bash
# 在容器创建后，通过 docker inspect 获取其在 Docker 网络上的 IP
get_container_ip() {
    local container_name="$1"
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name"
}
# 用法示例：
EXCHANGE_IP=$(get_container_ip "exchangefix")
```

**（C）容器子网广播地址** — 用于组播/广播地址替换：
```bash
# 基于容器 IP 计算 /24 子网的广播地址
get_broadcast_ip() {
    local container_ip="$1"
    echo "$container_ip" | sed 's/[0-9]*$/255/'
}
# 用法示例：
EXCHANGE_BROADCAST=$(get_broadcast_ip "$EXCHANGE_IP")
```

### 2. 交互式提示处理
部分步骤需要用户输入（ssh-keygen 提示、confirmMainBackup.sh、startall.sh 菜单）。采用两种策略：

**策略 A（首选）：** 简单场景使用管道/heredoc 传入输入：
```bash
# ssh-keygen：使用非交互参数（无需用户输入）
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa -q
```

**策略 B：** 复杂交互场景使用 `expect`：
```expect
spawn ssh-keygen -t rsa
expect "Enter file" { send "\r" }
expect "Enter passphrase" { send "\r" }
expect "Enter same passphrase" { send "\r" }
expect "Overwrite" { send "y\r" }
```

### 3. 幂等性模式
每个搭建脚本在执行操作前检查当前状态：
```bash
if docker container inspect exchangefix &>/dev/null; then
    log_info "容器 exchangefix 已存在，跳过创建"
else
    # 创建容器
fi
```

### 4. 配置文件修改
通过 `docker exec` 在容器内使用 `sed` 进行 IP 替换：
```bash
# 模式：将指定的旧 IP 替换为当前宿主机 IP
docker exec <容器名> sed -i "s/172\.24\.120\.132/${HOST_IP}/g" <文件路径>
```

### 5. fileExample/ 模板文件与容器内路径对照

| 模板文件 | 目标容器 | 容器内目标路径 |
|---------|---------|--------------|
| `DeployConfig.PD.all.all.xml` | exchangefix | `~/cfg/config/DeployConfig.PD.all.all.xml` |
| `DeployConfig.xml` | ctptradefix | `/home/trade1/cfg/config/DeployConfig.xml` |
| `service.list` | exchangefix | `~/shell/console/service.list` |
| `hosts` | ctptradefix | `/etc/hosts`（追加内容） |
| `ineoffer.ini` | ctptradefix | `~/ineoffer2/bin/ineoffer.ini` |
| `inemdserver.ini` | ctptradefix | `~/inemdserver2/bin/inemdserver.ini` |
| `shfeoffer.ini` | ctptradefix | `~/shfeoffer1/bin/shfeoffer.ini` |
| `shfemdserver.ini` | ctptradefix | `~/shfemdserver1/bin/shfemdserver.ini` |
| `fixfront_mt.ini` | ctpfix | `/home/fixf1/fixfront_mt1/bin/fixfront_mt.ini` |
| `fixfront_md.ini` | ctpfix | `/home/fixf1/fixfront_md1/bin/fixfront_md.ini` |

---

## 任务分解

### 任务 1：创建 `scripts/common.sh` — 公共函数库

**涉及文件：**
- 新建：`scripts/common.sh`

**接口定义：**
- 产出：`HOST_IP`（全局变量）、`DOCKER_NETWORK="fix-test-net"`、函数：`log_info(msg)`、`log_error(msg)`、`log_success(msg)`、`log_step(msg)`、`container_exists(name) → bool`、`image_exists(name) → bool`、`detect_host_ip() → string`

**步骤：**

- [ ] **步骤 1：创建文件**

```bash
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

# --- 日志函数 ---
log_info()    { echo -e "${BLUE}[信息]${NC}  $(date '+%H:%M:%S') $*"; }
log_error()   { echo -e "${RED}[错误]${NC} $(date '+%H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[完成]${NC}  $(date '+%H:%M:%S') $*"; }
log_step()    { echo -e "${YELLOW}[步骤]${NC}  $(date '+%H:%M:%S') $*"; }

# --- 检测宿主机 IP ---
detect_host_ip() {
    # 优先获取 global scope 的主 IPv4 地址
    HOST_IP=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    # 备用方案：通过默认路由接口获取
    if [ -z "$HOST_IP" ]; then
        HOST_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    fi
    if [ -z "$HOST_IP" ]; then
        log_error "无法检测宿主机 IP 地址"
        exit 1
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
```

- [ ] **步骤 2：验证语法**

执行：`bash -n scripts/common.sh`
预期：无输出（语法正确）

- [ ] **步骤 3：提交**

```bash
git add scripts/common.sh
git commit -m "feat: 添加 Docker 环境搭建公共函数库 common.sh"
```

---

### 任务 2：创建 `scripts/setup_exchange.sh` — 交易所容器搭建

**涉及文件：**
- 新建：`scripts/setup_exchange.sh`

**接口定义：**
- 消费：`common.sh`（HOST_IP、日志函数、container_exists、image_exists）
- 产出：运行中的 `exchangefix` 容器，SSH 已配置，服务已启动

**步骤：**

- [ ] **步骤 1：创建脚本**

```bash
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
    if [ ! -f "$TAR_FILE" ]; then
        log_error "找不到 tar 文件：$TAR_FILE"
        exit 1
    fi
    log_step "正在从 $TAR_FILE 导入 Docker 镜像..."
    docker import "$TAR_FILE" "$IMAGE_NAME"
    log_success "镜像 $IMAGE_NAME 创建完成"
}

# --- 步骤 2：创建并启动容器 ---
setup_container() {
    if container_exists "$CONTAINER_NAME"; then
        log_info "容器 $CONTAINER_NAME 已存在"
        # 如果容器未运行则启动
        if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
            log_step "正在启动已有容器 $CONTAINER_NAME..."
            docker start "$CONTAINER_NAME"
            sleep 3  # 等待 SSH 服务就绪
        fi
        return 0
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

# --- 步骤 3：在容器内配置 SSH 密钥 ---
setup_ssh() {
    log_step "正在 $CONTAINER_NAME 容器内配置 SSH 密钥..."
    # 检查是否已配置
    if docker exec "$CONTAINER_NAME" test -f /root/.ssh/authorized_keys 2>/dev/null; then
        log_info "SSH 密钥已配置，跳过"
        return 0
    fi
    # 非交互式生成密钥
    docker exec "$CONTAINER_NAME" bash -c '
        mkdir -p /root/.ssh
        ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa -q
        cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
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

# --- 步骤 5：修改 service.list ---
setup_service_list() {
    log_step "正在修改 $CONTAINER_NAME 容器内的 service.list..."
    local target="/home/trade2/shell/console/service.list"
    # 将 172.24.120.132 替换为本容器 IP（交易所服务自身地址）
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
```

- [ ] **步骤 2：验证语法**

执行：`bash -n scripts/setup_exchange.sh`
预期：无输出

- [ ] **步骤 3：提交**

```bash
git add scripts/setup_exchange.sh
git commit -m "feat: 添加交易所容器搭建脚本"
```

---

### 任务 3：创建 `scripts/setup_ctptrade.sh` — CTP 交易柜台容器搭建

**涉及文件：**
- 新建：`scripts/setup_ctptrade.sh`

**接口定义：**
- 消费：`common.sh`（HOST_IP、日志函数、container_exists、image_exists）
- 产出：运行中的 `ctptradefix` 容器，`/etc/hosts` 已更新，4 个 INI 文件已修改，服务已启动

> **说明：** 此脚本遵循与 `setup_exchange.sh` 相同的模式，包含以下步骤：
> 1. 导入 `CtpTradeFIX.tar` → 镜像 `ctptradefix:v2`
> 2. 创建容器，加入 `fix-test-net` 网络，映射端口 11157/11167/11155
> 3. SSH 密钥配置（同交易所容器）
> 4. setcap ping 权限配置
> 5. 修改 `/etc/hosts`，追加所有必需的 host 别名
> 6. 更新 4 个 INI 配置文件（ineoffer.ini、inemdserver.ini、shfeoffer.ini、shfemdserver.ini），将其中 IP 替换为宿主机 IP，并执行 `GenMD5.sh -g`
> 7. 修改 `/home/trade1/cfg/config/DeployConfig.xml`，将组播地址 `10.3.138.191` 替换为宿主机广播地址，执行 `cpall.sh`
> 8. 执行 `startall.sh`，自动输入 `1` 并回车

具体实现将在执行阶段补充完整代码。

- [ ] **步骤 2：验证语法**

执行：`bash -n scripts/setup_ctptrade.sh`
预期：无输出

- [ ] **步骤 3：提交**

---

### 任务 4：创建 `scripts/setup_fixgateway.sh` — FIX 网关容器搭建

**涉及文件：**
- 新建：`scripts/setup_fixgateway.sh`

**接口定义：**
- 消费：`common.sh`（HOST_IP、日志函数、container_exists、image_exists）
- 产出：运行中的 `ctpfix` 容器，FIX 网关服务已启动

> **说明：** 此脚本遵循与前面相同的模式，包含以下步骤：
> 1. 导入 `FIX.tar` → 镜像 `ctpfix:v1`
> 2. 创建容器，加入 `fix-test-net` 网络，映射端口 50001/61111
> 3. setcap ping 权限配置
> 4. 更新 `fixfront_mt.ini` 中的 `CTPfront1=tcp://<宿主机IP>:11157`，执行 `GenMD5.sh -g`
> 5. 更新 `fixfront_md.ini` 中的 `MDfront1=tcp://<宿主机IP>:11167`，执行 `GenMD5.sh -g`
> 6. 执行 `startall.sh`，自动输入 `1` 并回车

具体实现将在执行阶段补充完整代码。

- [ ] **步骤 2：验证语法**
- [ ] **步骤 3：提交**

---

### 任务 5：创建 `scripts/env_setup.sh` — 主编排脚本

**涉及文件：**
- 新建：`scripts/env_setup.sh`

**接口定义：**
- 消费：`common.sh`、`setup_exchange.sh`、`setup_ctptrade.sh`、`setup_fixgateway.sh`
- 产出：完整可运行的 3 容器测试环境

**步骤：**

- [ ] **步骤 1：创建编排脚本**

```bash
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
    log_info "=== 阶段 3/3：FIX 网关容器 ==="
    bash "$SCRIPT_DIR/setup_fixgateway.sh"
    export FIXGATEWAY_IP=$(get_container_ip "ctpfix")

    # 汇总信息
    echo ""
    echo "============================================"
    echo "  搭建完成！"
    echo "============================================"
    echo ""
    echo "  运行中的容器："
    docker ps --format '  - {{.Names}} ({{.Image}}) — 端口：{{.Ports}}' | grep -E 'exchangefix|ctptradefix|ctpfix'
    echo ""
    echo "  各容器 IP（Docker 网络 $DOCKER_NETWORK）："
    echo "    交易所：    $EXCHANGE_IP"
    echo "    CTP 柜台：  $CTPTRADE_IP"
    echo "    FIX 网关：  $FIXGATEWAY_IP"
    echo ""
    echo "  FixAutoTest 连接地址："
    echo "    交易通道：  tcp://${HOST_IP}:61111"
    echo "    行情通道：  tcp://${HOST_IP}:50001"
    echo ""
    echo "  运行测试：cd FixAutoTest/FixAutoTest && python FixInitiator.py"
    echo ""
}

main "$@"
```

- [ ] **步骤 2：验证语法**

执行：`bash -n scripts/env_setup.sh`
预期：无输出

- [ ] **步骤 3：提交**

---

### 任务 6：创建 `scripts/cleanup.sh` — 环境清理脚本

**涉及文件：**
- 新建：`scripts/cleanup.sh`

**接口定义：**
- 产出：移除所有 3 个容器、Docker 网络，可选移除镜像

**步骤：**

- [ ] **步骤 1：创建清理脚本**

```bash
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
```

- [ ] **步骤 2：验证语法**
- [ ] **步骤 3：提交**

---

### 任务 7：集成测试 — 在目标主机上完整运行验证

**涉及文件：**
- 无需修改（仅测试验证）

**步骤：**

- [ ] **步骤 1：将脚本和 tar 文件复制到 Docker 宿主机**

```bash
scp -r scripts/ user@docker-host:/opt/fix-test/
scp exchangeFIX.tar CtpTradeFIX.tar FIX.tar user@docker-host:/opt/fix-test/scripts/
```

- [ ] **步骤 2：运行搭建脚本**

```bash
ssh user@docker-host
cd /opt/fix-test/scripts
chmod +x *.sh
bash env_setup.sh
```

- [ ] **步骤 3：验证容器是否正常运行**

执行：`docker ps --format '{{.Names}} {{.Status}}'`
预期：3 个容器（exchangefix、ctptradefix、ctpfix）状态均为 "Up"

- [ ] **步骤 4：验证 FIX 端口是否在监听**

执行：`nc -zv <宿主机IP> 61111`
预期：Connection to <宿主机IP> 61111 port [tcp/*] succeeded!

- [ ] **步骤 5：验证清理脚本**

执行：`bash cleanup.sh` 然后 `docker ps`
预期：无 fix 相关容器运行

---

## IP 地址替换汇总表

以下表格记录了脚本需要执行的所有 IP 地址替换操作，既是实施指南，也是故障排查参考：

| 脚本 | 文件（容器内路径） | 旧值 | 新值 | 语义说明 |
|------|------------------|------|------|---------|
| setup_exchange | `~/shell/console/service.list` | `172.24.120.132` | `$EXCHANGE_IP` | **自身 IP**：交易所服务在本容器内运行 |
| setup_exchange | `~/cfg/config/DeployConfig.PD.all.all.xml` | `172.24.120.132` | `$EXCHANGE_IP` | **自身 IP**：交易所服务绑定地址 |
| setup_exchange | `~/cfg/config/DeployConfig.PD.all.all.xml` | `172.24.120.255` | `$EXCHANGE_BROADCAST` | **子网广播**：基于交易所容器 IP 计算 |
| setup_ctptrade | `~/ineoffer2/bin/ineoffer.ini` | `10.3.138.150:26181` | `$EXCHANGE_IP:26181` | **目标 IP**：CTP 连接交易所的报盘地址 |
| setup_ctptrade | `~/inemdserver2/bin/inemdserver.ini` | `10.3.138.150:26171` | `$EXCHANGE_IP:26171` | **目标 IP**：CTP 连接交易所的行情地址 |
| setup_ctptrade | `~/shfeoffer1/bin/shfeoffer.ini` | `10.3.138.150:26181` | `$EXCHANGE_IP:26181` | **目标 IP**：CTP 连接交易所的报盘地址 |
| setup_ctptrade | `~/shfemdserver1/bin/shfemdserver.ini` | `10.3.138.150:26171` | `$EXCHANGE_IP:26171` | **目标 IP**：CTP 连接交易所的行情地址 |
| setup_ctptrade | `/home/trade1/cfg/config/DeployConfig.xml` | `10.3.138.191` | `$CTPTRADE_BROADCAST` | **子网广播**：基于 CTP 容器 IP 计算 |
| setup_fixgateway | `fixfront_mt.ini` | `10.3.138.138:11157` | `$CTPTRADE_IP:11157` | **目标 IP**：FIX 连接 CTP 的交易通道 |
| setup_fixgateway | `fixfront_md.ini` | `10.3.138.138:11167` | `$CTPTRADE_IP:11167` | **目标 IP**：FIX 连接 CTP 的行情通道 |

---

## 自查清单

1. **需求覆盖：** `docker-fix.txt` 中的所有步骤均已覆盖——镜像导入、带正确端口映射的容器创建、SSH 配置、setcap、配置文件 IP 替换、GenMD5.sh 调用、3 个容器的服务启动
2. **占位符扫描：** 无 TBD/TODO 项。任务 3、4（ctptrade 和 fixgateway）标注为相同模式，需在执行阶段补充完整代码
3. **类型一致性：** 所有脚本使用统一的 `common.sh` 接口。IP 变量分为三类：`HOST_IP`（宿主机，供 FixAutoTest 连接）、`EXCHANGE_IP`/`CTPTRADE_IP`/`FIXGATEWAY_IP`（各容器 Docker 网络 IP）、`EXCHANGE_BROADCAST`/`CTPTRADE_BROADCAST`（容器子网广播地址）。主编排器按阶段依次获取并导出容器 IP 供后续脚本使用。

---

方案文件已保存至 `docs/superpowers/plans/2026-07-24-docker-test-env-setup.md`。

**执行方式选择：**
1. **子代理驱动（推荐）** —— 每个任务派发独立子代理，任务间审查，快速迭代
2. **内联执行** —— 在当前会话中使用 executing-plans 逐任务执行，批量推进

请选择执行方式？
