# Build
FROM alpine:3.22 AS builder

RUN apk add --no-cache \
    build-base \
    linux-headers \
    tcl

WORKDIR /build

COPY . .

RUN make -j$(nproc)

# Runtime
FROM alpine:3.22

WORKDIR /data

COPY --from=builder /build/src/valkey-server /usr/local/bin/
COPY --from=builder /build/src/valkey-cli /usr/local/bin/

EXPOSE 6379

CMD ["valkey-server", "--bind", "0.0.0.0", "--protected-mode", "no"]