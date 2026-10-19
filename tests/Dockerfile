FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl jq openssl tar gzip coreutils util-linux iproute2 \
    python3 shellcheck git docker.io docker-compose-v2 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
RUN apt-get update && apt-get install -y --no-install-recommends docker-buildx && rm -rf /var/lib/apt/lists/*
CMD ["bash", "tests/run.sh"]
