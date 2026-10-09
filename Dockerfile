FROM ruby:3.4-slim
ARG APP_VERSION=dev
ARG BUILD_TIME=
RUN apt-get update && apt-get install -y --no-install-recommends build-essential curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* && useradd -m -u 1000 app
WORKDIR /app
COPY Gemfile Gemfile.lock* ./
RUN bundle config set --local without development && bundle install && rm -rf /usr/local/bundle/cache
COPY . .
ENV APP_VERSION=$APP_VERSION BUILD_TIME=$BUILD_TIME RACK_ENV=production PORT=9292
USER app
EXPOSE 9292
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD curl -fsS http://localhost:${PORT:-9292}/health || exit 1
CMD ["sh", "-c", "exec bundle exec puma -b tcp://0.0.0.0:${PORT:-9292} -t ${PUMA_THREADS:-8} config.ru"]
