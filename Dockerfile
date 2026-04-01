# 仅用于测试 ODBC 安装的极简环境
FROM ubuntu:24.04
USER root
SHELL ["/bin/bash", "-c"]

# 消除交互式安装的弹窗
ENV DEBIAN_FRONTEND=noninteractive

# 1. 模拟前面的步骤：先安装基础工具 (curl 和 gnupg 是必须要的)
RUN apt-get update && apt-get install -y curl gnupg ca-certificates

# 2. 我们正在集中攻克和测试的 ODBC 驱动代码！
# 彻底废弃旧的 list 格式，改用 Ubuntu 24.04 最严格要求的 deb822 规范文件
RUN --mount=type=bind,from=infiniflow/ragflow_deps:latest,source=/,target=/deps \
    # 依然需要先装旧版 libssl
    if [ "$(uname -m)" = "x86_64" ]; then \
        dpkg -i /deps/libssl1.1_1.1.1f-1ubuntu2_amd64.deb; \
    elif [ "$(uname -m)" = "aarch64" ]; then \
        dpkg -i /deps/libssl1.1_1.1.1f-1ubuntu2_arm64.deb; \
    fi && \
    # 标准的新版微软证书和源注入流程
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg && \
    # 生成完全符合 deb822 规范的 .sources 文件
    echo "Types: deb\nURIs: https://packages.microsoft.com/ubuntu/22.04/prod\nSuites: jammy\nComponents: main\nArchitectures: amd64 armhf arm64\nSigned-By: /usr/share/keyrings/microsoft-prod.gpg\n" > /etc/apt/sources.list.d/mssql-release.sources && \
    # 清理一下旧的（如果有的话）
    rm -f /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    # 判断架构并安装驱动
    arch="$(uname -m)"; \
    if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then \
        ACCEPT_EULA=Y apt-get install -y unixodbc-dev msodbcsql18; \
    else \
        ACCEPT_EULA=Y apt-get install -y unixodbc-dev msodbcsql17; \
    fi
