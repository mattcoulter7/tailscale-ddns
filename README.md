# Tailscale Dynamic DNS Updater

This lightweight service dynamically updates your Tailscale tailnet’s DNS nameservers with the IPv4 addresses of Tailscale devices that match a configurable hostname pattern, provided that their `lastSeen` time is within a certain threshold.

## Features

- **Automatic Discovery** of devices by hostname prefix (e.g., `tailscale-proxy-dns-`).
- **Time-based Filtering**: Only includes devices whose `lastSeen` is within a configurable threshold, ensuring only recently online devices are included.
- **Redundancy & Load Balancing**: Multiple devices can be present in the global Tailscale DNS settings.
- **Environment-Configurable**: Easily change refresh intervals, Tailscale API URL, patterns, and more.

## Configuration

Set these environment variables to control the updater:

| Variable             | Default Value                           | Description                                                                                                      |
|----------------------|-----------------------------------------|------------------------------------------------------------------------------------------------------------------|
| **TAILSCALE_API_KEY** | *(Required)*                           | A Tailscale API key with permission to read device info and update DNS.                                         |
| **TAILNET**           | *(Required)*                           | Your Tailscale tailnet name, typically looks like `example.ts.net`.                                             |
| **DEVICE_PATTERN**    | *(Required)*                           | The hostname prefix used to filter devices (e.g., `tailscale-proxy-dns-`).                                      |
| **THRESHOLD_MINUTES** | `5`                                     | How many minutes old a device’s `lastSeen` can be to be considered online.                                      |
| **REFRESH_INTERVAL**  | `120`                                   | How many seconds to wait before re-checking devices and updating Tailscale DNS.                                 |
| **TAILSCALE_API_URL** | `https://api.tailscale.com/api/v2`      | Tailscale API endpoint (rarely changed).                                                                        |

## Quick Start (Docker)

1. **Build** or **pull** the image:
   ```bash
   docker pull mattcoulter7/tailscale-ddns:latest
   ```
2. **Run** with environment variables:
   ```bash
   docker run -it --rm \
     -e TAILSCALE_API_KEY="tskey-api-***" \
     -e TAILNET="your-tailnet.ts.net" \
     -e DEVICE_PATTERN="tailscale-proxy-dns-" \
     -e THRESHOLD_MINUTES=5 \
     -e REFRESH_INTERVAL=120 \
     --name tailscale-ddns \
     mattcoulter7/tailscale-ddns:latest
   ```

This container will periodically (every 120 seconds by default) update your tailnet’s DNS nameservers with any matches it finds.

## Kubernetes Deployment

Below is an example **Deployment** YAML snippet. It runs a single replica of the `tailscale-ddns` updater.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tailscale-ddns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tailscale-ddns
  template:
    metadata:
      labels:
        app: tailscale-ddns
    spec:
      containers:
        - name: tailscale-ddns
          image: mattcoulter7/tailscale-ddns:latest
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
                - NET_RAW
          env:
            - name: TAILSCALE_API_KEY
              value: "tskey-api-***"
            - name: TAILNET
              value: "tailb876d6.ts.net"
            - name: DEVICE_PATTERN
              value: "tailscale-proxy-dns-"
            # Optional environment vars:
            # - name: THRESHOLD_MINUTES
            #   value: "5"
            # - name: REFRESH_INTERVAL
            #   value: "120"
```

Apply it to your cluster:

```bash
kubectl apply -f tailscale-ddns-deployment.yaml
```

To observe logs:

```bash
kubectl logs -f deployment/tailscale-ddns
```

## Docker Compose

For environments using **docker-compose**, you can define a service like so:

```yaml
version: '3.7'
services:
  tailscale-ddns:
    image: mattcoulter7/tailscale-ddns:latest
    container_name: tailscale-ddns
    environment:
      - TAILSCALE_API_KEY=tskey-api-***
      - TAILNET=your-tailnet.ts.net
      - DEVICE_PATTERN=tailscale-proxy-dns-
      # Optional:
      # - THRESHOLD_MINUTES=5
      # - REFRESH_INTERVAL=120
    # Typically no special network is required. 
    # This container only needs outgoing internet to reach Tailscale's API.
```

Then start it with:
```bash
docker-compose up -d
```

## Usage & Operation

1. **Identifying Matching Devices**  
   Any Tailscale nodes whose `hostname` begins with your `DEVICE_PATTERN` and have been “online” in the last X minutes (as per `THRESHOLD_MINUTES`) will be included.

2. **DNS Updates**  
   The container sends a POST request to Tailscale’s API, setting your tailnet’s DNS nameservers to a JSON array of these device IPs. You can see these new DNS server entries in your Tailscale Admin Panel or by checking logs.

3. **Auto-Refresh**  
   The script repeats every `REFRESH_INTERVAL` seconds, re-checking and updating if device IPs have changed.

4. **High Availability**  
   Multiple devices can show up in your DNS servers list, letting you distribute DNS load or provide redundancy.

## Troubleshooting

- **Empty DNS Array**: If no matches are found, the updater sets or reverts to an empty array `[]`. Check your logs to ensure you have the correct `DEVICE_PATTERN` and confirm devices are online.
- **API Permissions**: Ensure your Tailscale API key has **`write`** permissions for DNS settings and **`read`** permissions for devices.
- **Pod/Container Capabilities**: `NET_ADMIN` and `NET_RAW` are typically not strictly required unless Tailscale is used within the container. This example retains them in case Tailscale is integrated.

## Contributing

Feel free to open issues or pull requests to improve this dynamic DNS updater.

---

**Enjoy automated, dynamic Tailscale DNS updates for your containerized environment!**
