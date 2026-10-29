ARG BASE=ubuntu:24.04
FROM ${BASE}
# curl/wget is the only bootstrap prerequisite. The installer resolves openssl,
# CA bundles and libcrypt when missing, without upgrading the entire machine.
RUN if command -v apt-get >/dev/null; then \
      apt-get update -qq && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*; \
    else \
      if ! command -v curl >/dev/null; then dnf install -y curl; fi && \
      dnf install -y ca-certificates && dnf clean all; fi
CMD ["sleep", "infinity"]
