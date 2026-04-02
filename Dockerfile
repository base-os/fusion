# ==========================================
# 文件名: Dockerfile.deps (第一阶段：基础环境镜像)
# 作用: 构建 RAGFlow 的专属基础环境与底层系统依赖
# 注意: 该镜像不包含 Python 虚拟环境(uv sync) 和 Node_modules 前端依赖
# ==========================================

# 强制使用你们公司内部的 Ubuntu 基础镜像 (与你的第二阶段对齐)
FROM ubuntu:24.04 AS base

USER root
SHELL ["/bin/bash", "-c"]

ARG NEED_MIRROR=0
WORKDIR /ragflow

# 1. 复制模型和外部依赖 (从官方 deps 镜像)
# 注意：这台机器必须能拉到 infiniflow/ragflow_deps:latest
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

# 2. 安装系统底层依赖、Nginx、Java、ODBC 等运行环境
# 【极致瘦身】：所有 apt 安装后必须紧跟 apt-get clean 和 rm -rf
RUN --mount=type=cache,id=ragflow_apt,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get --no-install-recommends install -y ca-certificates && \
    if [ "$NEED_MIRROR" == "1" ]; then \
        sed -i 's|http://archive.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources || true; \
        sed -i 's|http://security.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources || true; \
    fi && \
    apt-get update && \
    apt-get install -y libglib2.0-0 libglx-mesa0 libgl1 pkg-config libicu-dev libgdiplus default-jdk libatk-bridge2.0-0 libpython3-dev libgtk-4-1 libnss3 xdg-utils libgbm-dev libjemalloc-dev gnupg unzip curl wget git vim less ghostscript pandoc texlive fonts-freefont-ttf fonts-noto-cjk postgresql-client && \
    apt-get install -y --only-upgrade curl libcurl4 mupdf-tools libmupdf-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Nginx
ARG NGINX_VERSION=1.29.5-1~noble
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /etc/apt/keyrings/nginx-archive-keyring.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/ubuntu/ noble nginx" > /etc/apt/sources.list.d/nginx.list && \
    apt-get update && apt-get install -y nginx=${NGINX_VERSION} && apt-mark hold nginx && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 3. 安装 Python 管理器 (uv)、Node.js (20.x)、Rust
# 在线安装最新 uv，避免跨架构解压失败
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh && \
    uv python install 3.12

ENV PYTHONDONTWRITEBYTECODE=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
ENV PATH=/root/.local/bin:$PATH

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get purge -y nodejs npm cargo && \
    apt-get autoremove -y && \
    apt-get update && \
    apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y curl build-essential && \
    curl --proto '=https' --tlsv1.2 --http1.1 -sSf https://sh.rustup.rs | bash -s -- -y --profile minimal && \
    echo 'export PATH="/root/.cargo/bin:${PATH}"' >> /root/.bashrc && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
ENV PATH="/root/.cargo/bin:${PATH}"

# Microsoft ODBC (兼容 Ubuntu 24.04 的自动修补方案)
RUN --mount=type=bind,from=infiniflow/ragflow_deps:latest,source=/,target=/deps \
    curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/microsoft-prod.gpg && \
    curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list > /etc/apt/sources.list.d/mssql-release.list && \
    sed -i 's|deb \[|deb [signed-by=/usr/share/keyrings/microsoft-prod.gpg |g' /etc/apt/sources.list.d/mssql-release.list && \
    apt-get update && \
    arch="$(uname -m)"; \
    if [ "$arch" = "x86_64" ]; then \
        dpkg -i /deps/libssl1.1_1.1.1f-1ubuntu2_amd64.deb || true; \
    elif [ "$arch" = "aarch64" ]; then \
        dpkg -i /deps/libssl1.1_1.1.1f-1ubuntu2_arm64.deb || true; \
    fi && \
    apt-get --fix-broken install -y && \
    if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then \
        ACCEPT_EULA=Y apt-get install -y unixodbc-dev msodbcsql18; \
    else \
        ACCEPT_EULA=Y apt-get install -y unixodbc-dev msodbcsql17; \
    fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Chrome (无头浏览器)
RUN --mount=type=bind,from=infiniflow/ragflow_deps:latest,source=/chrome-linux64-121-0-6167-85,target=/chrome-linux64.zip \
    unzip /chrome-linux64.zip && mv chrome-linux64 /opt/chrome && ln -s /opt/chrome/chrome /usr/local/bin/
RUN --mount=type=bind,from=infiniflow/ragflow_deps:latest,source=/chromedriver-linux64-121-0-6167-85,target=/chromedriver-linux64.zip \
    unzip -j /chromedriver-linux64.zip chromedriver-linux64/chromedriver && mv chromedriver /usr/local/bin/ && rm -f /usr/bin/google-chrome
