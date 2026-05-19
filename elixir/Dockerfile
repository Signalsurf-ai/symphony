# syntax=docker/dockerfile:1

FROM elixir:1.19.5-otp-28-slim AS build

ENV MIX_ENV=prod
WORKDIR /build/elixir

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

COPY elixir/mix.exs elixir/mix.lock ./
RUN mix deps.get --only prod

COPY elixir ./
RUN mix escript.build

FROM elixir:1.19.5-otp-28-slim AS runtime

ARG CODEX_NPM_VERSION=0.131.0

ENV HOME=/home/surfer \
  MIX_ENV=prod \
  SURFER_WORKFLOW=/app/WORKFLOW.md

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    gh \
    git \
    nodejs \
    npm \
    openssh-client \
    sqlite3 \
  && npm install -g "@openai/codex@${CODEX_NPM_VERSION}" \
  && useradd --create-home --uid 10001 --shell /bin/bash surfer \
  && mkdir -p /app /srv/surfer/workspaces /srv/surfer/logs /srv/surfer/state /home/surfer/.codex \
  && chown -R surfer:surfer /app /srv/surfer /home/surfer \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /build/elixir/bin/symphony /usr/local/bin/surfer
COPY --chown=surfer:surfer elixir/SURFER_WORKFLOW.example.md /app/WORKFLOW.md

USER surfer
WORKDIR /app

EXPOSE 4000

VOLUME ["/srv/surfer/workspaces", "/srv/surfer/logs", "/srv/surfer/state", "/home/surfer/.codex"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD curl -fsS http://127.0.0.1:4000/api/v1/state >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/surfer"]
CMD ["--i-understand-that-this-will-be-running-without-the-usual-guardrails", "--logs-root", "/srv/surfer/logs", "--port", "4000", "/app/WORKFLOW.md"]
