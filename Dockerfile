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

# Render's containers typically run without the user-namespace privileges
# bubblewrap wants (see the CI's AppArmor workaround, which won't apply
# on Render). Disable the bwrap sandbox unless you've separately confirmed
# it works on your Render plan; leaving this on makes game launches fail silently.
ENV NO_BWRAP=true
ENV NODE_ENV=production

# Render provides $PORT at runtime; relay already reads process.env.PORT
EXPOSE 8080

# Games are fetched/built on demand into a directory relative to relay —
# mount a Render persistent Disk here so game data survives redeploys.
VOLUME ["/app/relay/games"]

CMD ["node", "relay/dist/src/index.js"]
