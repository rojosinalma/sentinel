# syntax=docker/dockerfile:1
FROM ruby:3.4-slim

# Hook dependencies on top of the app: hooks are typically bash and drive ssh, docker (via the
# mounted socket), sqlite3 and curl/jq; flock comes from util-linux, ping from iputils
# (quorum/icmp probes). The docker CLI + compose plugin are the static builds, arch-selected so
# the same Dockerfile builds for amd64 and arm64.
ARG TARGETARCH
ARG DOCKER_VERSION=27.3.1
ARG COMPOSE_VERSION=2.29.7

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates \
      bash openssh-client sqlite3 jq util-linux iputils-ping procps \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) darch=x86_64; carch=x86_64 ;; arm64) darch=aarch64; carch=aarch64 ;; *) echo "unsupported arch $arch"; exit 1 ;; esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${darch}/docker-${DOCKER_VERSION}.tgz" \
      | tar -xz -C /usr/local/bin --strip-components=1 docker/docker; \
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
      "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${carch}"; \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

ARG APP_UID=1000
ARG APP_GID=1000
RUN groupadd -g "$APP_GID" app 2>/dev/null || true; \
    useradd -m -u "$APP_UID" -g "$APP_GID" -s /bin/bash app

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without development && bundle install --jobs 4

# hooks/ is in this copy only as a fallback: every compose mounts the checkout's hooks/ over it
# (docs/hooks.md), so a hook change is a file drop, not a rebuild.
COPY . .
# data/ (state, logs, sqlite) must be writable by the unprivileged user even without a volume;
# with a bind mount, create the host dir yourself first so it is not root-owned (README).
RUN mkdir -p data && chown -R app:app data

LABEL org.opencontainers.image.source="https://github.com/rojosinalma/sentinel" \
      org.opencontainers.image.description="Majority-vote failover for self-hosted services: probes, quorum, majority lease, promote/demote hooks" \
      org.opencontainers.image.licenses="MIT"

ARG APP_VERSION=dev
ARG BUILD_TIME=""
ENV APP_VERSION=$APP_VERSION \
    BUILD_TIME=$BUILD_TIME \
    RACK_ENV=production \
    BUNDLE_FROZEN=true \
    PORT=9292

USER app
EXPOSE 9292

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD curl -fsS "http://localhost:${PORT:-9292}/health" || exit 1

CMD ["sh", "-c", "exec bundle exec puma -b tcp://0.0.0.0:${PORT:-9292} -t ${PUMA_THREADS:-8} config.ru"]
