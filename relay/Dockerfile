# Build from the repository root, so the shared clearcut_core package is
# available:  docker compose up -d --build  (from the relay folder)

FROM dart:3.13.6 AS build
WORKDIR /src

# Dependencies first, so code changes don't re-download them.
COPY packages/clearcut_core/pubspec.yaml packages/clearcut_core/
COPY relay/pubspec.yaml relay/pubspec.lock relay/
RUN cd relay && dart pub get

COPY packages/clearcut_core packages/clearcut_core
COPY relay relay
WORKDIR /src/relay
RUN dart pub get --offline \
    && dart test \
    && mkdir -p /out \
    && dart compile exe bin/relay.dart -o /out/relay

# A minimal image: the compiled relay and the few system files it needs.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /out/relay /usr/local/bin/relay
ENV PATH=/usr/local/bin \
    RELAY_DATA_DIR=/data \
    RELAY_PORT=8080
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["relay"]
CMD ["serve"]
