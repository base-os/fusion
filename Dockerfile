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
    # 先配置好合法的微软源
    curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/microsoft-prod.gpg && \
    curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list > /etc/apt/sources.list.d/mssql-release.list && \
    sed -i 's|deb \[|deb [signed-by=/usr/share/keyrings/microsoft-prod.gpg |g' /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    # 先把那个该死的、依赖残缺的老包强装进去（这时候 dpkg 会报错，但不退出）
    arch="$(uname -m)"; \
    if [ "$arch" = "x86_64" ]; then \
        dpkg -i /deps/libssl1.1_1.1.1f-1ubuntu2_amd64.deb || true; \
    elif [ "$arch" = "aarch64" ]; then \
        dpkg -i /deps/libssl1.1_1.1.1f-1ubuntu2_arm64.deb || true; \
    fi && \
    # 【最关键的一步】：使用 apt-get --fix-broken install 强行把破坏的依赖树给缝合好！
    apt-get --fix-broken install -y && \
    # 然后再安心安装驱动，世界清静了
    if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then \
        ACCEPT_EULA=Y apt-get install -y unixodbc-dev msodbcsql18; \
    else \
        ACCEPT_EULA=Y apt-get install -y unixodbc-dev msodbcsql17; \
    fi
