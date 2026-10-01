# vpn2proxy agent skill

Teaches a coding agent to drive the **vpn2proxy** control-plane API: turn a
proxy you already pay for into a real WireGuard/OpenVPN server on hardware you
control, and hand the resulting VPN profile to a device.

vpn2proxy wraps SOCKS5/HTTP proxies into real VPN servers. Traffic leaves
through your own proxy provider — nothing relays through vpn2proxy.

## Install

Clone into your agent's skills directory:

```bash
git clone https://github.com/VPN2Proxy/vpn2proxy-skill.git \
  ~/.claude/skills/vpn2proxy
```

Or copy `SKILL.md`, `references/`, and `scripts/` into an existing skills
folder. The skill needs no dependencies beyond `curl` and `jq` for the
optional helper script.

## Use

Start from `SKILL.md`. It covers the provisioning workflow and the traps that
silently break an otherwise-correct agent:

- the header is `authorization: Bearer v2p_…` — there is no `x-api-key`
- provisioning waits **twice**, and the two waits fail differently
  (`devices.request` → 404 "not live yet"; `devices.profile` → 409)
- there is no `devices.list`, so you poll `devices.profile` and branch on
  409 vs 200
- `endpoints.create` cannot take a `proxySlotId`
- `devices.profile` is **write-scoped**, so a read-only key cannot fetch it
- branch on the HTTP status: pre-dispatch failures carry no `code` field
- admin-only actions are 403 for API keys regardless of grants

`references/actions.md` is the full action reference with required input and
response shape per action.

## Auth

Mint a key in the dashboard under **API keys** (shown once), then:

```bash
export VPN2PROXY_API_KEY=v2p_...
./scripts/vpn2proxy-api.sh vpn2proxy.regions.list
```

Pick **Read only** for anything that only reports; it cannot create, change,
or disable. The default limit is 1000 requests/hour.

A machine-readable manifest of every action, with scope and a summary, is
public and needs no key:

```bash
curl -s https://vpn2proxy.com/api/agent/capabilities
```

That route is the source of truth. If it disagrees with the skill, it wins.

## Transport

HTTP only. **MCP is deliberately not enabled** on the production deployment —
`POST /mcp` answers 404 — so do not build against it.

## License

MIT — see [LICENSE](LICENSE).
