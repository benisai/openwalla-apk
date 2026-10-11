FROM alpine:3.22

RUN apk add --no-cache openssh-server

COPY tunnel/entrypoint.sh /usr/local/bin/openwalla-tunnel-entrypoint
RUN chmod 0755 /usr/local/bin/openwalla-tunnel-entrypoint

EXPOSE 22 10080 10022

ENTRYPOINT ["/usr/local/bin/openwalla-tunnel-entrypoint"]
