# The web edition, in one container: the Swift engine server plus the built
# browser app it serves. Build from the REPO ROOT (the server package
# depends on the root package by path):
#
#   docker build -f server/Dockerfile -t piperstitch-web .
#   docker run -p 8080:8080 piperstitch-web
#
# The Mac app is never built here -- SwiftPM only compiles the targets the
# server product needs (StitchPilotCore + StitchPilotServer).

# --- 1. the browser app -----------------------------------------------------
FROM node:20-bookworm-slim AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# --- 2. the Swift server ----------------------------------------------------
FROM swift:6.1-noble AS build
WORKDIR /src
# Manifests first so dependency resolution is cached across source edits.
COPY Package.swift ./
COPY server/Package.swift server/
RUN mkdir -p Sources/StitchPilotCore Sources/StitchPilotApp Sources/DigitizeCLI Tests/StitchPilotCoreTests server/Sources/StitchPilotServer
COPY Sources/ Sources/
COPY Tests/ Tests/
COPY server/Sources/ server/Sources/
WORKDIR /src/server
RUN swift build -c release --static-swift-stdlib --product StitchPilotServer

# --- 3. runtime -------------------------------------------------------------
FROM swift:6.1-noble-slim
RUN useradd --create-home --user-group piperstitch
WORKDIR /app
COPY --from=build /src/server/.build/release/StitchPilotServer ./
COPY --from=web /web/dist ./Public
USER piperstitch
ENV PORT=8080 HOST=0.0.0.0
EXPOSE 8080
CMD ["./StitchPilotServer", "serve", "--env", "production"]
