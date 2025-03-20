# Tailscale Dynamic DNS Updater

A lightweight service that dynamically updates:

1. **Tailscale Global DNS** (via the Tailscale API).  
2. A **dnsmasq** config file inside the same Pod, forcing `dnsmasq` to reload with the new IP addresses.

## How It Works

1. **Tailscale Container**  
   Joins your cluster Pod to the Tailscale network using user-mode networking.

2. **dnsmasq Container**  
   Hosts a local DNS server, reading config snippets from `/etc/dnsmasq.d/`. When the `tailscale-ddns-updater` writes a new config, it forcibly **kills** and restarts the dnsmasq process (using the shared process namespace), ensuring the new IP addresses take effect immediately.

3. **tailscale-ddns-updater**  
   - Scans your tailnet (via Tailscale API) for devices matching a configured prefix, ensuring they’ve been seen within the last `THRESHOLD_SECONDS`.
   - Writes those devices’ IPs into Tailscale’s global DNS and into a local dnsmasq config file at `/etc/dnsmasq.d/tailscale-dns.conf`.
   - Triggers dnsmasq to reload by killing the dnsmasq process, which Kubernetes automatically restarts (thanks to the liveness probe and shared process namespace).

4. **socat** (Optional)  
   Forwards traffic from Tailscale-exposed ports to internal cluster services or the host node. This is how you might expose HTTP/HTTPS, Samba, SSH, or other services over Tailscale.

## Features

- **Automated Discovery**: Finds Tailscale devices by hostname prefix.
- **Time-Based Filtering**: Only includes devices that have been seen recently.
- **Global & Local DNS Updates**: Integrates with Tailscale’s DNS settings and updates local dnsmasq config in one step.
- **Forced Reload of dnsmasq**: Ensures changes are applied immediately.
- **High Availability**: Multiple IPs can be included for redundancy.

## Configuration

Configure by setting these environment variables in the **tailscale-ddns-updater** container:

| Variable                | Default Value                            | Description                                                                                                              |
|-------------------------|------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| **TAILSCALE_API_KEY**   | *(Required)*                             | A Tailscale API key with permission to read device info and update DNS.                                                  |
| **TAILNET**             | *(Required)*                             | Your Tailscale tailnet name (e.g., `myorg.ts.net`).                                                                      |
| **DEVICE_PATTERN**      | *(Required)*                             | Hostname prefix used to filter Tailscale devices (e.g., `tailscale-ddns-`).                                              |
| **DOMAIN**              | *(Required)*                             | Domain mapped to Tailscale IPs by both the Tailscale admin console and dnsmasq (e.g., `myservice.local`).                |
| **THRESHOLD_SECONDS**   | `30`                                     | How many seconds old a device’s `lastSeen` can be to be considered online.                                               |
| **REFRESH_INTERVAL**    | `30`                                     | How many seconds to wait before re-checking devices and updating Tailscale DNS + dnsmasq.                                 |
| **TAILSCALE_API_URL**   | `https://api.tailscale.com/api/v2`       | Tailscale API endpoint (rarely changed).                                                                                 |
| **DNSMASQ_CONFIG_PATH** | `/etc/dnsmasq.d/tailscale-dns.conf`      | Where the dnsmasq config snippet for Tailscale IPs is written.                                                           |

### Tailscale API Permissions

Your **TAILSCALE_API_KEY** must have:

- **Device Read** permission (to list and filter devices).
- **DNS Write** permission (to set your tailnet’s global DNS nameservers).

## Kubernetes Deployment (Advanced Setup)

In this example, we have:

- **dnsmasq**: Local DNS server reading from `/etc/dnsmasq.d`.
- **tailscale**: Joins the Pod to the Tailscale network in user-mode networking.
- **tailscale-ddns-updater**: Periodically updates Tailscale’s DNS and the dnsmasq config, then **kills** dnsmasq to force a reload.
- **socat**: Optionally forwards Tailscale traffic (on various ports) into your cluster or node.

> **Important**:  
> - `shareProcessNamespace: true` is crucial; it lets the updater send signals to the dnsmasq process.  
> - The `dnsmasq-dynamic-config` volume is an `emptyDir`, which the updater writes to and dnsmasq reads from.  
> - The `livenessProbe` on dnsmasq ensures if the process is killed, Kubernetes automatically restarts it with the updated config.

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
      # Must be enabled so the ddns-updater can kill dnsmasq directly.
      shareProcessNamespace: true

      # Example node selector to schedule on a node labeled "tailscale=true".
      nodeSelector:
        tailscale: "true"

      containers:
        # 1. DNSMASQ CONTAINER
        - name: dnsmasq
          image: jpillora/dnsmasq:latest
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
                - NET_RAW
          volumeMounts:
            - name: dnsmasq-config
              mountPath: /etc/dnsmasq.conf
              subPath: dnsmasq.conf
            - name: dnsmasq-dynamic-config
              mountPath: /etc/dnsmasq.d
          # If dnsmasq is killed, the liveness probe fails, and K8s restarts it
          livenessProbe:
            exec:
              command:
                - sh
                - -c
                - "pgrep dnsmasq || exit 1"
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 2
            successThreshold: 1

        # 2. TAILSCALE CONTAINER
        - name: tailscale
          image: tailscale/tailscale:latest
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
                - NET_RAW
          env:
            - name: TS_AUTHKEY
              value: "tskey-auth-***"
          command: ["/bin/sh"]
          args:
            - -c
            - |
              tailscaled --tun=userspace-networking &
              sleep 5
              tailscale up --authkey=$TS_AUTHKEY
              sleep infinity

        # 3. TAILSCALE-DDNS-UPDATER CONTAINER
        - name: tailscale-ddns-updater
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
              value: "mytailnet.ts.net"
            - name: DEVICE_PATTERN
              value: "tailscale-ddns-"
            - name: DOMAIN
              value: "myservice.local"
            - name: THRESHOLD_SECONDS
              value: "30"
            - name: REFRESH_INTERVAL
              value: "30"
            - name: DNSMASQ_CONFIG_PATH
              value: "/etc/dnsmasq.d/tailscale-dns.conf"
          volumeMounts:
            - name: dnsmasq-dynamic-config
              mountPath: /etc/dnsmasq.d

        # 4. SOCAT CONTAINER (OPTIONAL, CAN BE MULTIPLE)
        - name: socat-traefik
          image: alpine/socat:latest
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
          command:
            - sh
            - -c
            - |
              sleep 5
              # Forward port 80 and 443 on Tailscale interface to a Traefik service
              socat TCP-LISTEN:80,reuseaddr,fork TCP:traefik.kube-system.svc.cluster.local:80 &
              socat TCP-LISTEN:443,reuseaddr,fork TCP:traefik.kube-system.svc.cluster.local:443 &
              # Example forwarding for Samba, SSH, etc. can be added similarly
              wait

      volumes:
        # Primary dnsmasq config from a ConfigMap or other source
        - name: dnsmasq-config
          configMap:
            name: dnsmasq-config
        # Dynamic config is placed here by tailscale-ddns-updater
        - name: dnsmasq-dynamic-config
          emptyDir: {}
```

Apply it to your cluster:
```bash
kubectl apply -f tailscale-ddns-deployment.yaml
```

Check logs:
```bash
kubectl logs -f deployment/tailscale-ddns -c tailscale-ddns-updater
```
_(Replace container name to see other logs, e.g., `-c dnsmasq`.)_

### Key Components

1. **dnsmasq**  
   - Responsible for handling DNS queries in the Pod.  
   - Reads static config from `/etc/dnsmasq.conf` plus dynamic config from `/etc/dnsmasq.d/`.  
   - A **livenessProbe** restarts it whenever the ddns-updater kills it to refresh IPs.

2. **tailscale**  
   - Joins this Pod to your Tailscale network in user-mode networking.  
   - Grants the Pod a Tailscale IP address so you can SSH in, forward traffic, or run services exposed to Tailscale.

3. **tailscale-ddns-updater**  
   - Periodically queries Tailscale’s API for devices that match `DEVICE_PATTERN` and have been seen recently (`THRESHOLD_SECONDS`).  
   - Updates Tailscale’s global DNS nameservers to these device IPs.  
   - Writes the same IP list into `/etc/dnsmasq.d/tailscale-dns.conf`, then kills dnsmasq so it reloads instantly.

4. **socat** (Optional)  
   - Any number of `socat` sidecars can forward inbound traffic from Tailscale to internal cluster services.  
   - Useful for exposing HTTP/HTTPS, Samba, SSH, or any TCP/UDP service.

## Operation & Troubleshooting

1. **Periodic Refresh**  
   The ddns-updater runs every `REFRESH_INTERVAL` seconds. If it detects new IPs, it updates the dnsmasq config and restarts dnsmasq.

2. **Checking Tailscale**  
   - Use `kubectl exec` into the `tailscale` container to run `tailscale status` or `tailscale ip` to check your Pod’s Tailscale connection.

3. **Empty DNS Array**  
   If no matches are found, Tailscale’s DNS is set to an empty array `[]`. Confirm your `DEVICE_PATTERN` is correct and that devices have checked in recently.

4. **API Permissions**  
   Ensure `TAILSCALE_API_KEY` has enough scope to read devices and write DNS.

5. **Rate Limits**  
   Tailscale has API rate limits. Avoid extremely low intervals (like <10 seconds).

6. **Logs**  
   - `kubectl logs -f deployment/tailscale-ddns -c tailscale-ddns-updater` to see ddns-updater logs.  
   - `kubectl logs -f deployment/tailscale-ddns -c dnsmasq` to see dnsmasq logs.  
   - If a container is repeatedly crashing, check the logs to see why.

## Contributing

Issues and pull requests are welcome! Feel free to add more advanced forwarding scenarios, new configuration options, or improvements to the ddns-updater logic.

---

**Enjoy automated, dynamic Tailscale DNS updates with dnsmasq and a shared Kubernetes Pod!**