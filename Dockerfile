# ==========================================
# 文件名: Dockerfile.deps
# 作用: 构建基础环境、安装系统依赖、下载 Python/Node 库
# ==========================================
FROM ubuntu:24.04
USER root
SHELL ["/bin/bash", "-c"]

ARG NEED_MIRROR=0
WORKDIR /ragflow

# 1. 复制模型和外部依赖 (从官方 deps 镜像)
RUN mkdir -p /ragflow/rag/res/deepdoc /root/.ragflow
RUN --mount=type=bind,from=infiniflow/ragflow_deps:latest,source=/huggingface.co,target=/huggingface.co \
    tar --exclude='.*' -cf - \
        /huggingface.co/InfiniFlow/text_concat_xgb_v1.0 \
        /huggingface.co/InfiniFlow/deepdoc \
        | tar -xf - --strip-components=3 -C /ragflow/rag/res/deepdoc

RUN --mount=type=bind,from=infiniflow/ragflow_deps:latest,source=/,target=/deps \
    cp -r /deps/nltk_data /root/ && \
    cp /deps/tika-server-standard-3.2.3.jar /deps/tika-server-standard-3.2.3.jar.md5 /ragflow/ && \
    cp /deps/cl100k_base.tiktoken /ragflow/9b5ad71b2ce5302211f9c61530b329a4922fc6a4

ENV TIKA_SERVER_JAR="file:///ragflow/tika-server-standard-3.2.3.jar"
ENV DEBIAN_FRONTEND=noninteractive

# 2. 安装系统底层依赖、Nginx、Java、ODBC
RUN --mount=type=cache,id=ragflow_apt,target=/var/cache/apt,sharing=locked \
    apt update && apt --no-install-recommends install -y ca-certificates; \
    rm -f /etc/apt/apt.conf.d/docker-clean && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache && \
    chmod 1777 /tmp && apt update && \
    apt install -y libglib2.0-0 libglx-mesa0 libgl1 pkg-config libicu-dev libgdiplus default-jdk libatk-bridge2.0-0 libpython3-dev libgtk-4-1 libnss3 xdg-utils libgbm-dev libjemalloc-dev gnupg unzip curl wget git vim less ghostscript pandoc texlive fonts-freefont-ttf fonts-noto-cjk postgresql-client


RUN arch="$(uname -m)"; \
    if [ "$arch" = "x86_64" ]; then \
        wget -qO /tmp/libmupdf.deb "http://security.ubuntu.com/ubuntu/pool/universe/m/mupdf/libmupdf-dev_1.23.10+ds1-1ubuntu0.1_amd64.deb" && \
        wget -qO /tmp/mupdf-tools.deb "http://security.ubuntu.com/ubuntu/pool/universe/m/mupdf/mupdf-tools_1.23.10+ds1-1ubuntu0.1_amd64.deb"; \
    elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then \
        wget -qO /tmp/libmupdf.deb "http://ports.ubuntu.com/pool/universe/m/mupdf/libmupdf-dev_1.23.10+ds1-1ubuntu0.1_arm64.deb" && \
        wget -qO /tmp/mupdf-tools.deb "http://ports.ubuntu.com/pool/universe/m/mupdf/mupdf-tools_1.23.10+ds1-1ubuntu0.1_arm64.deb"; \
    fi && \
    dpkg -i /tmp/libmupdf.deb /tmp/mupdf-tools.deb || true && \
    apt-get --fix-broken install -y && \
    rm -f /tmp/libmupdf.deb /tmp/mupdf-tools.deb

    
# Nginx
ARG NGINX_VERSION=1.29.5-1~noble
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /etc/apt/keyrings/nginx-archive-keyring.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/ubuntu/ noble nginx" > /etc/apt/sources.list.d/nginx.list && \
    apt update && apt install -y nginx=${NGINX_VERSION} && apt-mark hold nginx

# 3. 安装 Python 管理器 (uv)、Node.js (20.x)、Rust
# [核心修复区] 直接用 curl 从官方拉取安装脚本，彻底绕过跨架构 tar 解压报错
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh && \
    uv python install 3.12

ENV PYTHONDONTWRITEBYTECODE=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
ENV PATH=/root/.local/bin:$PATH

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt purge -y nodejs npm cargo && apt autoremove -y && apt update && apt install -y nodejs
RUN apt update && apt install -y curl build-essential && curl --proto '=https' --tlsv1.2 --http1.1 -sSf https://sh.rustup.rs | bash -s -- -y --profile minimal && echo 'export PATH="/root/.cargo/bin:${PATH}"' >> /root/.bashrc
ENV PATH="/root/.cargo/bin:${PATH}"

# Microsoft ODBC
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

# Chrome
RUN --mount=type=bind,from=infiniflow/ragflow_deps:latest,source=/chrome-linux64-121-0-6167-85,target=/chrome-linux64.zip \
    unzip /chrome-linux64.zip && mv chrome-linux64 /opt/chrome && ln -s /opt/chrome/chrome /usr/local/bin/
RUN --mount=type=bind,from=infiniflow/ragflow_deps:latest,source=/chromedriver-linux64-121-0-6167-85,target=/chromedriver-linux64.zip \
    unzip -j /chromedriver-linux64.zip chromedriver-linux64/chromedriver && mv chromedriver /usr/local/bin/ && rm -f /usr/bin/google-chrome
RUN apt-get purge -y curl libcurl4 && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
