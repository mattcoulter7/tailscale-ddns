FROM alpine:latest

RUN apk add --no-cache curl jq

COPY bin/tailscale-ddns.sh /usr/local/bin/tailscale-ddns.sh
RUN chmod +x /usr/local/bin/tailscale-ddns.sh
RUN sed -i 's/\r//' /usr/local/bin/tailscale-ddns.sh

ENTRYPOINT ["/usr/local/bin/tailscale-ddns.sh"]
