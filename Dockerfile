# syntax=docker/dockerfile:1

#######################################
# Stage 1: Build client + relay + server
#######################################
FROM node:24-bookworm AS builder

# curl/git: elan install + fetching deps; build-essential: native module builds
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

# elan (Lean version manager) — installs to /root/.elan
ENV ELAN_HOME=/root/.elan
ENV PATH=$ELAN_HOME/bin:$PATH
RUN curl https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -sSf \
    | sh -s -- --default-toolchain none -y

WORKDIR /app

# Cypress is a test-only devDependency with a large binary download that
# has no purpose in a production image build — skip it.
ENV CYPRESS_INSTALL_BINARY=0

# Install JS deps first for better layer caching (npm workspaces:
# root package-lock.json covers client + relay together)
COPY package.json package-lock.json ./
COPY client/package.json ./client/package.json
COPY relay/package.json ./relay/package.json
RUN npm install

# Bring in the rest of the source
COPY . .

# Resolve the Lean toolchain declared by the server project, then build it
RUN cd server && elan toolchain install $(cat lean-toolchain) \
    && elan override set $(cat lean-toolchain)

RUN npm run build:server
RUN npm run build:relay
RUN npm run build:client

#######################################
# Stage 1b: Pull in a game (built from source, no GitHub token needed)
#######################################
# Clones the game's own repo and builds it exactly the way
# doc/running_locally.md tells contributors to do it locally:
#   lake update -R && lake exe cache get && lake build
# This produces the same .lake/gamedata/*.json + compiled output that
# relay's GameManager.getGameDir() (relay/src/serverProcess.ts) expects at
# <repo-root>/games/<owner>/<repo> — no GitHub Actions artifact/token needed.
#
# `lake exe cache get` fetches Mathlib's precompiled .olean cache instead of
# compiling Mathlib from source — skip it and a Mathlib-dependent game will
# try to build Mathlib itself, which is realistically hours of build time.
# Games that don't depend on Mathlib simply won't have a `cache` target;
# the fallback below lets the step no-op for those instead of failing the build.
#
# --- To add this game, just set these three lines: ---
ARG GAME_OWNER=leanprover-community
ARG GAME_REPO=nng4

RUN set -e; \
    OWNER=$(echo "${GAME_OWNER}" | tr '[:upper:]' '[:lower:]'); \
    REPO=$(echo "${GAME_REPO}" | tr '[:upper:]' '[:lower:]'); \
    mkdir -p "games/${OWNER}"; \
    git clone --depth 1 "https://github.com/${GAME_OWNER}/${GAME_REPO}.git" "games/${OWNER}/${REPO}"; \
    cd "games/${OWNER}/${REPO}"; \
    elan toolchain install $(cat lean-toolchain); \
    lake update -R; \
    lake exe cache get || echo "No Mathlib cache target for ${OWNER}/${REPO} — skipping."; \
    lake build; \
    rm -rf .git

# --- To add a SECOND (or third, etc.) game, copy-paste this block, give it
# a distinct stage name, and change only the owner/repo on the git clone
# line. Example for the Set Theory Game: ---
#
# RUN set -e; \
#     OWNER=djvelleman; REPO=stg4; \
#     mkdir -p "games/${OWNER}"; \
#     git clone --depth 1 "https://github.com/${OWNER}/${REPO}.git" "games/${OWNER}/${REPO}"; \
#     cd "games/${OWNER}/${REPO}"; \
#     elan toolchain install $(cat lean-toolchain); \
#     lake update -R; \
#     lake exe cache get || echo "No Mathlib cache target for ${OWNER}/${REPO} — skipping."; \
#     lake build; \
#     rm -rf .git

#######################################
# Stage 2: Runtime image
#######################################
FROM node:24-bookworm AS runtime

# git: required at runtime to fetch/update individual game repos
# bubblewrap: sandboxes spawned Lean game-server processes (see NO_BWRAP below)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates bubblewrap \
    && rm -rf /var/lib/apt/lists/*

# elan/lean toolchain required at runtime too — relay spawns
# `lake serve` / gameserver binaries per game on demand
ENV ELAN_HOME=/root/.elan
ENV PATH=$ELAN_HOME/bin:$PATH
COPY --from=builder /root/.elan /root/.elan

WORKDIR /app

# Production node_modules only (npm workspaces installs client+relay deps
# into the shared root node_modules where possible)
COPY package.json package-lock.json ./
COPY client/package.json ./client/package.json
COPY relay/package.json ./relay/package.json
RUN npm install --omit=dev

# Built artifacts from the builder stage
COPY --from=builder /app/relay/dist ./relay/dist
COPY --from=builder /app/client/dist ./client/dist
COPY --from=builder /app/server ./server

# The game(s) pulled in during the build stage above. Games live at
# <repo-root>/games/<owner>/<repo> — confirmed by tracing
# GameManager.getGameDir() in relay/src/serverProcess.ts, which resolves
# this path relative to relay/dist/src at runtime.
COPY --from=builder /app/games ./games

# Render's containers typically run without the user-namespace privileges
# bubblewrap wants (see the CI's AppArmor workaround, which won't apply
# on Render). Disable the bwrap sandbox unless you've separately confirmed
# it works on your Render plan; leaving this on makes game launches fail silently.
ENV NO_BWRAP=true
ENV NODE_ENV=production

# To import additional games later via GET /import/trigger/:owner/:repo,
# set these as regular Render environment variables (not build secrets —
# these are read at runtime by relay/src/import.ts):
#   LEAN4GAME_GITHUB_USER, LEAN4GAME_GITHUB_TOKEN, ISSUE_CONTACT

# Render provides $PORT at runtime; relay already reads process.env.PORT
EXPOSE 8080

# Additional games beyond the one baked in above get fetched at runtime
# (via this app's own GET /import/trigger/:owner/:repo endpoint) into this
# same directory. Mount a Render persistent Disk here so anything imported
# after deploy survives redeploys — otherwise it's lost every rebuild.
VOLUME ["/app/games"]

CMD ["node", "relay/dist/src/index.js"]
