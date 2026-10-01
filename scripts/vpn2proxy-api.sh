#!/usr/bin/env bash
# vpn2proxy control-plane API wrapper.
#
#   export VPN2PROXY_API_KEY=v2p_...
#   ./vpn2proxy-api.sh vpn2proxy.regions.list
#   ./vpn2proxy-api.sh vpn2proxy.endpoints.create '{"regionCode":"de1"}'
#   ./vpn2proxy-api.sh vpn2proxy.devices.profile '{"deviceId":"..."}'
#
# Prints the `data` payload on success (raw JSON) and exits non-zero on
# ok:false, so it composes with jq. The full envelope goes to stderr.
#
# Header is `authorization: Bearer v2p_...` — there is no x-api-key support.
# Scope: read-only keys can call *.list/get and are refused (403) anything
# that writes, including devices.profile.

set -euo pipefail

BASE_URL="${VPN2PROXY_BASE_URL:-https://vpn2proxy.com}"
ACTION="${1:-}"
INPUT="${2:-{\}}"

if [[ -z "$ACTION" ]]; then
  echo "usage: $0 <action> [json-input]" >&2
  exit 2
fi
if [[ -z "${VPN2PROXY_API_KEY:-}" ]]; then
  echo "error: set VPN2PROXY_API_KEY to a v2p_ key from the dashboard" >&2
  exit 2
fi

resp=$(curl -sS -o /tmp/.vpn2proxy.$$ -w '%{http_code}' -X POST "$BASE_URL/api/agent/action" \
  -H "authorization: Bearer ${VPN2PROXY_API_KEY}" \
  -H "content-type: application/json" \
  -d "$(jq -cn --arg a "$ACTION" --argjson i "$INPUT" '{action: $a, input: $i}')")
body=$(cat /tmp/.vpn2proxy.$$); rm -f /tmp/.vpn2proxy.$$

# Branch on the HTTP status: pre-dispatch rejections (bad JSON, bad key) come
# back as a bare {ok,error} with no `code` field, so the status is the only
# always-correct signal.
if [[ "$resp" != "200" ]] || [[ "$(jq -r '.ok // false' <<<"$body")" != "true" ]]; then
  echo "error [$resp]: $(jq -r '.error // "unknown error"' <<<"$body")" >&2
  exit 1
fi

jq -c '.data' <<<"$body"
