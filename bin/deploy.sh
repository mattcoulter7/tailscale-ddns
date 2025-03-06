docker build -f Dockerfile -t tailscale-ddns:latest .
docker login
docker tag tailscale-ddns:latest mattcoulter7/tailscale-ddns:latest
docker push mattcoulter7/tailscale-ddns:latest
