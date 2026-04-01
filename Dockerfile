FROM docker.artifactrepo.wux-g.tools.xfusion.com/seclab/repo/ragflow:2026040102
USER root
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade openssl curl wget git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    # 卸载旧版本（如果有的话）
    apt-get purge -y nodejs npm && \
    apt-get autoremove -y && \
    # 安装新版本
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
RUN /ragflow/.venv/bin/python3 -m pip install --upgrade --no-cache-dir \
    pip \
    setuptools \
    requests \
    urllib3 \
    certifi \
    cryptography
