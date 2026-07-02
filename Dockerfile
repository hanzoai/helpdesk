# syntax=docker/dockerfile:1.7
# Hanzo Help Center — Frappe Helpdesk on Base/SQLite.
#
# Proves the "one Frappe-core -> all Frappe apps" thesis: the SAME recipe
# (bench + hanzoai/frappe SQLite driver) is reused across every Frappe app;
# only the app layer (helpdesk) swaps. Second Frappe app after hanzoai/erp.
#
# Data model: org == tenant. One SQLite site per org, persisted on the
# mounted volume (Hanzo Base/SQLite). No MariaDB, no Postgres, no external DB.
# Built on-cluster via arcd/BuildKit (never GitHub builders, never locally).

ARG PYTHON_VERSION=3.14
FROM python:${PYTHON_VERSION}-slim-trixie AS build

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    NODE_MAJOR=20 \
    BENCH_DIR=/home/frappe/frappe-bench \
    PATH=/home/frappe/.local/bin:$PATH

# Frappe system dependencies. SQLite is stdlib in CPython, so no DB client.
# wkhtmltopdf for PDF/print, redis-server for cache/queue/socketio (in-pod),
# node for the frappe-ui / helpdesk SPA asset build.
ARG WKHTMLTOX_DEB=https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates build-essential pkg-config \
      redis-server \
      libffi-dev libssl-dev \
      fontconfig libjpeg62-turbo libxrender1 libxext6 xfonts-75dpi xfonts-base \
      fonts-cantarell \
      gettext \
    # wkhtmltopdf (patched-Qt static build; the apt package was dropped in trixie)
    && wget -q -O /tmp/wkhtmltox.deb "${WKHTMLTOX_DEB}" \
    && apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb \
    && rm -f /tmp/wkhtmltox.deb \
    && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g yarn \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -ms /bin/bash frappe
USER frappe
WORKDIR /home/frappe

# frappe-bench CLI
RUN pip install --user frappe-bench

# Initialise a bench against the Hanzo Frappe core (carries the SQLite driver).
ARG FRAPPE_REPO=https://github.com/hanzoai/frappe
ARG FRAPPE_BRANCH=develop
RUN bench init --skip-redis-config-generation --verbose \
      --frappe-path ${FRAPPE_REPO} --frappe-branch ${FRAPPE_BRANCH} \
      frappe-bench

WORKDIR ${BENCH_DIR}

# telephony is a hard frappe-dependency of helpdesk (pyproject).
RUN bench get-app --skip-assets https://github.com/frappe/telephony

# helpdesk itself, from THIS build context (the hanzoai/helpdesk fork).
COPY --chown=frappe:frappe . /home/frappe/helpdesk-src
RUN bench get-app /home/frappe/helpdesk-src

# Build all frontend assets (frappe desk + helpdesk SPA).
RUN bench build --production

# Assets are CODE, not data: snapshot the built sites/ tree (apps.txt +
# assets symlink targets + default configs) so the entrypoint can restore
# them on top of the persistent (data-only) volume at every boot.
RUN cp -a ${BENCH_DIR}/sites /home/frappe/sites-template

COPY --chown=frappe:frappe deploy/entrypoint.sh /home/frappe/entrypoint.sh
RUN chmod +x /home/frappe/entrypoint.sh

EXPOSE 8000 9000
ENTRYPOINT ["/home/frappe/entrypoint.sh"]
