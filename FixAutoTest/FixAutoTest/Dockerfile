FROM centos:7

LABEL description="FIX AutoTest Runner - 自动化测试执行环境"

# 安装 Python 3.6 和编译依赖
RUN yum install -y epel-release && \
    yum install -y python36 python36-pip python36-devel gcc-c++ && \
    yum clean all && rm -rf /var/cache/yum

# 升级 pip + 安装 wheel
RUN pip3 install --upgrade pip && pip3 install wheel

# 创建工作目录
WORKDIR /opt/fix-test

# 安装 xlrd（纯 Python，直接安装）
RUN pip3 install xlrd==1.2.0

# 编译 quickfix（在镜像构建时完成编译）
RUN pip3 install quickfix==1.15.1

# 验证安装
RUN python3 -c "import quickfix; import _quickfix; print('quickfix OK')" && \
    python3 -c "import xlrd; print('xlrd OK')"

# 复制测试脚本（构建时从宿主机复制）
COPY FixInitiator.py tags.py generate_report.py launcher.sh caselist.txt ./
COPY fix42-*.ini fix42.xml ./
COPY testcase/ testcase/
COPY initiator/ initiator/

# 默认命令：运行全部用例
CMD ["bash", "launcher.sh"]
