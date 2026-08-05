#!/usr/bin/env bash
# export_runner_image.sh — 将现有服务器环境打包为 Docker 镜像压缩包
# 用法: 在已部署好的服务器上运行
#   bash export_runner_image.sh
# 产出: softpackage/fix-runner.tar
#
# 原理:
#   1. 启动一个临时容器（centos:7 base）
#   2. 将 /opt/fix-test 目录复制进去
#   3. docker commit 生成镜像
#   4. docker save 导出为 .tar

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/../FixAutoTest/FixAutoTest/softpackage"
IMAGE_NAME="fix-runner:v1"
OUTPUT_TAR="$OUTPUT_DIR/fix-runner.tar"
FIXAUTO_DIR="$SCRIPT_DIR/../FixAutoTest/FixAutoTest"
SRC_DIR="/opt/fix-test"

echo "========================================="
echo "  打包 fix-runner Docker 镜像"
echo "========================================="
echo ""

# 检查源目录
if [ ! -d "$FIXAUTO_DIR" ] && [ ! -d "/opt/fix-test" ]; then
    echo "错误: 找不到 FixAutoTest 目录"
    echo "请确认目录存在于: $FIXAUTO_DIR 或 /opt/fix-test"
    exit 1
fi

# 检查是否能联网（尝试拉取 centos:7）
CAN_PULL=false
if docker pull centos:7 --disable-content-trust 2>/dev/null; then
    CAN_PULL=true
fi

# 方法 A：在线 Dockerfile 构建
if [ "$CAN_PULL" = true ] && [ -f "$FIXAUTO_DIR/Dockerfile" ]; then
    echo "使用 Dockerfile 构建镜像..."
    if docker build -t "$IMAGE_NAME" -f "$FIXAUTO_DIR/Dockerfile" "$FIXAUTO_DIR" 2>&1; then
        echo "Dockerfile 构建成功"
    else
        echo "Dockerfile 构建失败，回退到容器 commit 方式..."
        CAN_PULL=false
    fi
fi

# 方法 B：从现有容器 commit（离线兼容）
if [ "$CAN_PULL" = false ]; then
    echo "从现有环境创建镜像（离线模式）..."

    # 查找已存在的容器作为 base
    BASE_CONTAINER=""
    for name in exchangefix ctptradefix ctpfix; do
        if docker inspect "$name" &>/dev/null; then
            BASE_CONTAINER="$name"
            break
        fi
    done

    if [ -z "$BASE_CONTAINER" ]; then
        echo "错误: 未找到运行中的容器作为 base"
        echo "请先运行 env_setup.sh 部署环境"
        exit 1
    fi

    echo "以 $BASE_CONTAINER 为 base 创建 runner 容器..."

    # 在 base 容器中安装测试依赖
    docker exec "$BASE_CONTAINER" bash -c '
        if ! command -v python3.6 &>/dev/null && ! command -v python3 &>/dev/null; then
            yum install -y epel-release && yum install -y python36 python36-pip || true
        fi
        # 创建 python3 别名（CentOS 7 默认只有 python3.6）
        if [ -f /usr/bin/python3.6 ] && [ ! -f /usr/bin/python3 ]; then
            ln -sf /usr/bin/python3.6 /usr/bin/python3
            ln -sf /usr/bin/pip3.6 /usr/bin/pip3 2>/dev/null || true
        fi
        pip3 install --no-index --find-links=/opt/fix-test/softpackage/ quickfix xlrd 2>/dev/null || \
        pip3 install quickfix==1.15.1 xlrd==1.2.0 2>/dev/null || true
    '

    # 复制测试脚本
    TEMP_CONTAINER="fix-runner-temp"
    docker rm -f "$TEMP_CONTAINER" 2>/dev/null || true
    BASE_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$BASE_CONTAINER")
    docker run -d --name "$TEMP_CONTAINER" "$BASE_IMAGE" sleep infinity
    docker exec "$TEMP_CONTAINER" mkdir -p /opt/fix-test
    docker cp "$FIXAUTO_DIR/." "$TEMP_CONTAINER:/opt/fix-test/"
    docker commit "$TEMP_CONTAINER" "$IMAGE_NAME"
    docker rm -f "$TEMP_CONTAINER"
    echo "镜像创建成功（基于 $BASE_CONTAINER）"
fi

# 导出镜像
echo ""
echo "导出镜像为 $OUTPUT_TAR ..."
mkdir -p "$OUTPUT_DIR"
docker save -o "$OUTPUT_TAR" "$IMAGE_NAME"

echo ""
echo "========================================="
echo "  完成!"
echo "========================================="
echo ""
echo "镜像文件: $OUTPUT_TAR ($(du -h "$OUTPUT_TAR" | cut -f1))"
echo ""
echo "部署到目标机器:"
echo "  # 1. 复制到目标机器"
echo "  scp $OUTPUT_TAR user@target:/opt/fix-test/scripts/"
echo ""
echo "  # 2. 导入镜像"
echo "  docker load -i /opt/fix-test/scripts/fix-runner.tar"
echo ""
echo "  # 3. 运行测试"
echo "  docker run --rm --network=host -e FIX_HOST=HOST_IP fix-runner:v1"
echo ""
