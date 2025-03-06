#!/bin/sh

TAILNET="$TAILNET"
TAILSCALE_API_KEY="$TAILSCALE_API_KEY"
TAILSCALE_API_URL="${TAILSCALE_API_URL:-https://api.tailscale.com/api/v2}"
DEVICE_PATTERN="$DEVICE_PATTERN"
DNSMASQ_CONFIG_PATH="${TAILSCALE_DNSMASQ_CONFIG_PATH:-/etc/dnsmasq.d/tailscale-dns}"
DOMAIN="$DOMAIN"

# Default threshold of 30 seconds if not set:
THRESHOLD_SECONDS="${THRESHOLD_SECONDS:-30}"

# Default refresh interval of 30 seconds if not set:
REFRESH_INTERVAL="${REFRESH_INTERVAL:-30}"

if [ -z "$DOMAIN" ]; then
  echo "[ERROR] DOMAIN environment variable is required."
  exit 1
fi

if [ -z "$DEVICE_PATTERN" ]; then
  echo "[ERROR] DEVICE_PATTERN environment variable is required."
  exit 1
fi

echo "[INFO] TAILNET: $TAILNET"
echo "[INFO] DEVICE_PATTERN: $DEVICE_PATTERN"
echo "[INFO] TAILSCALE_API_URL: $TAILSCALE_API_URL"
echo "[INFO] THRESHOLD_SECONDS: $THRESHOLD_SECONDS"
echo "[INFO] REFRESH_INTERVAL: $REFRESH_INTERVAL seconds"

touch "$DNSMASQ_CONFIG_PATH"
OLD_DNS=""

while true; do
  echo "--------------------------------------------------------------------------------"
  echo "[$(date -u)] [INFO] Querying Tailscale API for tailnet '$TAILNET'..."

  # Fetch the full JSON for all devices
  ALL_DEVICES_JSON=$(curl -s -H "Authorization: Bearer $TAILSCALE_API_KEY" \
    "$TAILSCALE_API_URL/tailnet/$TAILNET/devices")

  # Count total devices for quick reference
  TOTAL_DEVICES=$(echo "$ALL_DEVICES_JSON" | jq -r '.devices | length')
  echo "[$(date -u)] [INFO] Received $TOTAL_DEVICES devices from Tailscale."

  # Current UTC time in epoch seconds
  NOW=$(date -u +%s)

  # Filter out devices that:
  # 1) have hostname starting with DEVICE_PATTERN
  # 2) lastSeen is within THRESHOLD_SECONDS
  # 3) only return IPv4 addresses
  DNS_IPS=$(echo "$ALL_DEVICES_JSON" | jq -r --arg pattern "$DEVICE_PATTERN" \
    --argjson now "$NOW" --argjson threshold "$THRESHOLD_SECONDS" '
      .devices[]
      | (.lastSeen | sub("\\..*"; "")) as $lsStr
      | ($lsStr | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $lsEpoch
      | select(.hostname | startswith($pattern))
      | select(($now - $lsEpoch) < $threshold)
      | .addresses[]
      | select(test("^[0-9]+\\.")) # picks IPv4
    '
  )

  if [ -n "$DNS_IPS" ]; then
    echo "[$(date -u)] [INFO] Matched IPs:"
    echo "$DNS_IPS" | sed 's/^/[INFO]  - /'
  else
    echo "[$(date -u)] [WARN] No devices matched pattern '$DEVICE_PATTERN' within last $THRESHOLD_SECONDS seconds."
  fi

  # Sort and remove duplicates; convert to JSON array for Tailscale
  DNS_JSON=$(echo "$DNS_IPS" | sort -u | jq -R -s -c 'split("\n")[:-1]')

  # If no addresses, DNS_JSON will become [], which is valid
  if [ -z "$DNS_JSON" ]; then
    DNS_JSON="[]"
  fi

  # Only update Tailscale DNS if the new IP list differs from old
  if [ "$DNS_JSON" != "$OLD_DNS" ]; then
    echo "[$(date -u)] [INFO] DNS IPs have changed from $OLD_DNS to $DNS_JSON. Updating Tailscale..."

    # Make the POST request to set these IPs
    UPDATE_RESPONSE=$(curl -s -X POST "$TAILSCALE_API_URL/tailnet/$TAILNET/dns/nameservers" \
      -H "Authorization: Bearer $TAILSCALE_API_KEY" \
      -d "{\"dns\": $DNS_JSON}")

    echo "[$(date -u)] [INFO] Updated Tailscale DNS servers to: $DNS_JSON"
    echo "[$(date -u)] [INFO] Tailscale API response: $UPDATE_RESPONSE"

    OLD_DNS="$DNS_JSON"
  else
    echo "[$(date -u)] [INFO] IP set unchanged. No Tailscale update needed."
  fi

  # Only update this if it is different to the existing config -
  # we don't want to unnecessarily restart dnsmasq if nothing has changed
  TEMP_CONFIG_PATH="/tmp/tailscale-dnsmasq.conf"

  # Generate new dnsmasq config in a temporary file
  > "$TEMP_CONFIG_PATH"  # Clear temporary file
  for IP in $DNS_IPS; do
    echo "address=/$DOMAIN/$IP" >> "$TEMP_CONFIG_PATH"
  done

  # Compare with existing config, and only update if there are changes
  if ! cmp -s "$TEMP_CONFIG_PATH" "$DNSMASQ_CONFIG_PATH"; then
    echo "[$(date -u)] [INFO] DNS configuration has changed. Updating $DNSMASQ_CONFIG_PATH and reloading dnsmasq."

    # Overwrite the actual config file with the updated one
    mv "$TEMP_CONFIG_PATH" "$DNSMASQ_CONFIG_PATH"

    # Reload dnsmasq
    if pgrep dnsmasq > /dev/null; then
      echo "[$(date -u)] [INFO] Reloading dnsmasq"
      pgrep dnsmasq | xargs kill -9
    else
      echo "[$(date -u)] [WARN] dnsmasq not running. Skipping reload."
    fi
  else
    echo "[$(date -u)] [INFO] No changes to dnsmasq config. Skipping reload."
    rm -f "$TEMP_CONFIG_PATH"
  fi

  echo "[$(date -u)] [INFO] Sleeping for $REFRESH_INTERVAL seconds before next check."
  sleep "$REFRESH_INTERVAL"
done
