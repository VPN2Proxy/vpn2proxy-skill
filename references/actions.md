# Action reference

Every machine-callable action. Names are authoritative in code at
`website/src/lib/server/agent.ts` (`AGENT_ACTIONS`); the live manifest at
`GET https://vpn2proxy.com/api/agent/capabilities` is the same list with
per-action summaries and scope.

Call shape for all of them:

```
POST https://vpn2proxy.com/api/agent/action
authorization: Bearer v2p_…
content-type: application/json

{"action": "<name>", "input": { … }}
```

## Reading

### `vpn2proxy.regions.list` — read
No input. `data` = array of
`{code, city, country, countryCode, vultrRegion, host, wgPort, status, sortOrder, hostStatus, hostStale}`.
Only create endpoints in a region whose `status` is `available`.

### `vpn2proxy.endpoints.list` — read
No input. `data` = array of `EndpointRow`:

`id, name, region, regionCity, regionCountry, provisioning, protocol,
endpointHost, endpointPort, status, upstreamSummary, applyState, applyNote,
claimedBy, claimedAt, createdAt, orgId, orgName, canManage, lastHandshake,
usage7d, pendingReplacement, hostStatus, hostStale, proxySlotId,
proxySlotName, proxySlotSummary`

- `applyState`: `queued` → `applying` → `applied`, or `failed` / `removing` / `removed`
- `status`: `active` / `idle` / `error` / `disconnected` (derived from host health + an upstream probe — **not** a per-tunnel handshake)
- `upstreamSummary` / `proxySlotSummary` are credential-free summaries, never credentials
- `applyNote` carries the exact failure reason and is credential-free. The host
  probes the upstream before applying, so `failed` is most often an unreachable
  or unresolvable proxy: `upstream probe failed, config untouched: … CONNECT=FAIL
  (gaierror: …)`. A `gaierror` is a DNS failure on the proxy host; a refused
  CONNECT or timeout is reachability or bad credentials.

### `vpn2proxy.slots.list` — read
No input. `data` = array of
`{id, userId, orgId, name, provider, server, port, hasCredential, summary, createdAt, updatedAt, removedAt, canManage}`.

### `vpn2proxy.capacity.get` — read
No input. `data` = plan, container type, and configured/purchased counts for
proxy slots, VPN endpoints, and connections, plus Free-plan cooldown state.
Personal container only.

### `vpn2proxy.activity.list` — read
Optional `limit` (default 12, cap 100). `data` = `{kind, message, createdAt}`,
newest first. Includes your own `agent.action` audit rows.

### `vpn2proxy.endpoints.rotationPlan` — read
Required `endpointId`. `data` = `{endpointId, name, region, regionCity,
provisioning, applyState, pendingReplacement, hasUpstream, eligible,
blockers[], automated:false, steps[]}`. **Read-only report** — the executing
write is `endpoints.replaceCredential`.

## Writing

### `vpn2proxy.endpoints.create` — write
| Input | Required | Notes |
|---|---|---|
| `regionCode` | yes | must exist and be `available` |
| `protocol` | no | `"openvpn"` or wireguard; anything else → wireguard |
| `name` | no | ≤64 chars; defaults to `"WireGuard · <city>"` |
| `upstream` | no | `{provider, server, port, username?, password}` — creates a proxy slot for you |

`provider` is `socks5` or `http`. `port` 1–65535, `username` ≤128,
`password` 1–256. **Write-only** — stored sealed, never returned.
`proxySlotId` is **not** accepted here; use `endpoints.assign`.

`data` = `{endpoint:{…}}`, created with `applyState:"queued"`. Asynchronous —
wait for `applied` (see the workflow in `SKILL.md`).

### `vpn2proxy.slots.create` — write
Required `name`, `server`, `port`, `password`. Optional `provider`
(`"http"` or socks5), `username`. `data` = `{slot:{…}}`. Stores credentials
sealed; the password is never returned.

### `vpn2proxy.slots.update` — write
Required `slotId`. Optional `name`, `provider`, `server`, `port`, `username`,
`password` — only what you pass is changed. `data` = `{slotId, renamed,
connectionChanged}`. Changing connection fields may hit the Free-plan
one-change-per-24h cooldown.

### `vpn2proxy.slots.remove` — write
Required `slotId`. `data` = `{slotId, outcome:"removed", unassignedEndpoints}`.
Endpoints that lose their slot **fail closed** (traffic blocked, never leaked).

### `vpn2proxy.endpoints.assign` — write
Required `endpointId`; `slotId` key must be **present** — a slot id to bind,
or `null` to unassign. `data` = `{endpointId, assigned, requeued}`.

### `vpn2proxy.endpoints.replaceCredential` — write
Required `endpointId` and `upstream{server, port, password}`; optional
`upstream.username`, `upstream.provider` (defaults socks5). Stages a new
credential; the host validates before switching, so a bad value never breaks a
working tunnel. `data` = `{renamed, replacement:"none"|"staged"}`. Goes live
only after the host acks — until then `pendingReplacement` is true.

### `vpn2proxy.endpoints.reapply` — write
Required `endpointId`. Re-queues the endpoint for the host. `data` =
`{endpointId, applyState:"queued"}`. Used after changing a credential or to
recover a `failed` endpoint.

### `vpn2proxy.devices.request` — write
Required `endpointId` (must be `provisioning:"provisioned"` **and**
`applyState:"applied"`, else 404 "This endpoint is not live yet") and `name`
(1–64 chars). `data` = `{device:{id, name}}`.

**The profile is not returned here.** The host generates and seals it
asynchronously; fetch it with `devices.profile`. Asynchronous.

### `vpn2proxy.devices.profile` — write
Required `deviceId`. `data` = `{device:{id, name}, profile: "<config text>"}`.

**The only action that returns credential material**, so it is write-scoped
and a read-only key is refused 403. Owner-scoped. Delivered once, re-readable
only inside a short recovery window, then the sealed copy is wiped — after
that a new credential needs a fresh `devices.request`. Audited as its own
action; the audit row never contains the profile.

Poll this for readiness: **409** = not provisioned yet, **404** = no such
device, **200** = profile ready. `profile` is a WireGuard `.conf` or an
OpenVPN `.ovpn` document.

### `vpn2proxy.devices.disable` — write
Required `deviceId`. Queues credential revocation and frees an account-wide
connection slot; the owning host removes it on a later pass. `data` =
`{device:{id, name, state}}`.

## Admin-only — always 403 for API keys

Refused for API keys, agents, and MCP regardless of grants or the user's role;
these require a real admin **session**.

- `vpn2proxy.health.list` — read. Fleet health for enrolled hosts.
- `vpn2proxy.fleet.housekeeping` — write. Bounded retention over control-plane
  data. **Dry run unless `confirm:"yes"`**; optional `endpointUsageDays`,
  `deviceUsageDays`, `tombstoneDays`, `counters`, `maxRows`.

## Not exposed to machines

- **No organization actions** — org administration is dashboard-only.
- **No host actions** — host enrollment/report/claim is a separate
  region-token surface under `/api/hosts/*`, not the agent API.
- **No `devices.list`** — poll `devices.profile` instead.
- **No endpoint removal.** There is no action to remove an endpoint or revoke
  a removed device; both are dashboard operations. The API covers create,
  read, update, reassign, and credential replacement.
- **MCP is off.** `POST /mcp` answers 404 unless the deployment sets
  `MCP_ENABLED=yes`, and it is deliberately left unset. Do not build against
  it.
