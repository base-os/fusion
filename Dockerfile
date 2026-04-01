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
    if [ "$NEED_MIRROR" == "1" ]; then \
        sed -i 's|http://archive.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources; \
        sed -i 's|http://security.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources; \
    fi; \
    rm -f /etc/apt/apt.conf.d/docker-clean && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache && \
    chmod 1777 /tmp && apt update && \
    apt install -y libglib2.0-0 libglx-mesa0 libgl1 pkg-config libicu-dev libgdiplus default-jdk libatk-bridge2.0-0 libpython3-dev libgtk-4-1 libnss3 xdg-utils libgbm-dev libjemalloc-dev gnupg unzip curl wget git vim less ghostscript pandoc texlive fonts-freefont-ttf fonts-noto-cjk postgresql-client

# Nginx
ARG NGINX_VERSION=1.29.5-1~noble
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /etc/apt/keyrings/nginx-archive-keyring.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/ubuntu/ noble nginx" > /etc/apt/sources.list.d/nginx.list && \
    apt update && apt install -y nginx=${NGINX_VERSION} && apt-mark hold nginx

# 3. 安装 Python 管理器 (uv)、Node.js (20.x)、Rust
RUN --mount=type=bind,from=infiniflow/ragflow_deps:latest,source=/,target=/deps \
    arch="$(uname -m)"; if [ "$arch" = "x86_64" ]; then uv_arch="x86_64"; else uv_arch="aarch64"; fi; \
    tar xzf "/deps/uv-${uv_arch}-unknown-linux-gnu.tar.gz" && cp "uv-${uv_arch}-unknown-linux-gnu/"* /usr/local/bin/ && uv python install 3.12

ENV PYTHONDONTWRITEBYTECODE=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
ENV PATH=/root/.local/bin:$PATH

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt purge -y nodejs npm cargo && apt autoremove -y && apt update && apt install -y nodejs
RUN apt update && apt install -y curl build-essential && curl --proto '=https' --tlsv1.2 --http1.1 -sSf https://sh.rustup.rs | bash -s -- -y --profile minimal && echo 'export PATH="/root/.cargo/bin:${PATH}"' >> /root/.bashrc
ENV PATH="/root/.cargo/bin:${PATH}"

# Microsoft ODBC
RUN curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add - && \
    curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list > /etc/apt/sources.list.d/mssql-release.list && \
    apt update && ACCEPT_EULA=Y apt install -y unixodbc-dev msodbcsql17

# Chrome
RUN --mount=type=bind,from=infiniflow/ragflow_deps:latest,source=/chrome-linux64-121-0-6167-85,target=/chrome-linux64.zip \
    unzip /chrome-linux64.zip && mv chrome-linux64 /opt/chrome && ln -s /opt/chrome/chrome /usr/local/bin/
RUN --mount=type=bind,from=infiniflow/ragflow_deps:latest,source=/chromedriver-linux64-121-0-6167-85,target=/chromedriver-linux64.zip \
    unzip -j /chromedriver-linux64.zip chromedriver-linux64/chromedriver && mv chromedriver /usr/local/bin/ && rm -f /usr/bin/google-chrome

# 4. 安装 Python 依赖包 (放入 .venv)
COPY pyproject.toml  ./
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh && \
    uv python install 3.12

# 5. 安装前端 Node 依赖包
COPY package.json  web/
RUN cd web && npm install
