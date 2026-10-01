---
name: vpn2proxy
description: Drive the vpn2proxy control-plane API to turn a user's existing SOCKS5/HTTP proxy into a real WireGuard or OpenVPN VPN — create endpoints, store proxy credentials, attach devices, and fetch VPN profiles. Use when provisioning, rotating, or auditing vpn2proxy VPN endpoints, proxy slots, or client devices from an agent or script, or when asked to set up vpn2proxy on a host.
---

# vpn2proxy API

vpn2proxy wraps proxies a user **already pays for** (DataImpulse, Webshare,
Bright Data, …) into real WireGuard/OpenVPN servers on hardware they control.
Traffic leaves through their own proxy; nothing relays through vpn2proxy.

This skill drives the HTTP control plane. **MCP is not used** — it is
deliberately not enabled on the deployment.

## Auth

Base URL: `https://vpn2proxy.com`

```bash
curl -sS -X POST https://vpn2proxy.com/api/agent/action \
  -H "authorization: Bearer $VPN2PROXY_API_KEY" \
  -H "content-type: application/json" \
  -d '{"action":"vpn2proxy.regions.list"}'
```

- Header is **`authorization: Bearer v2p_…`**. There is no `x-api-key` header;
  it is not read anywhere.
- Keys are created in the dashboard under **API keys** and shown once.
- Pick **Read only** for anything that only reports. `read` covers every
  `*.list`/`get`; `write` is required for anything that creates, changes, or
  disables, **including fetching a device profile**.
- Default limit is 1000 requests/hour. Handle HTTP 429 by backing off.
- Every call is written to the account's activity feed as an `agent.action`
  row, so your own calls show up in `activity.list`.

## Envelope

Request: `{"action": "<action name>", "input": { … }}` — the field is `input`.

Success:

```json
{ "ok": true, "action": "vpn2proxy.regions.list", "data": { } }
```

Failure — the shape depends on how far the request got:

```jsonc
// rejected before dispatch (bad JSON, missing/invalid key) — no code/action:
{ "ok": false, "error": "Authentication required: Better Auth session or a v2p_ API key." }

// rejected by the action itself — code is in the body AND the status:
{ "ok": false, "action": "vpn2proxy.devices.profile", "code": 409, "error": "No profile is waiting for this device." }
```

**Branch on the HTTP status, not `.code`** — it is always present and correct.
`.code` only exists on the second shape.

Status codes: `400` bad/missing input (including a non-JSON body) · `401`
missing or invalid key · `403` scope or admin refusal · `404` unknown action
**or** unknown endpoint/device · `409` not ready · `429` rate limited.

`GET /api/agent/capabilities` is public and returns the full manifest with
per-action summaries — the authoritative list, including scope. Prefer it
over this file when they disagree.

## Provisioning workflow

Endpoint and device creation are **both asynchronous**: a host in the target
region picks up the work and reports back. You must wait twice. Do not assume
success on the creating call.

**1 — Pick a region.** `vpn2proxy.regions.list` → choose a row whose
`status` is `"available"`. Note its `code`.

**2 — Create the endpoint.**

```bash
-d '{"action":"vpn2proxy.endpoints.create","input":{
      "regionCode":"de1","protocol":"wireguard","name":"home-lab",
      "upstream":{"provider":"socks5","server":"p.example.com","port":1080,
                  "username":"u","password":"p"}}}'
```

`protocol` defaults to `wireguard` (anything not `"openvpn"` becomes
`wireguard`). Returns `{endpoint:{…}}` with `applyState:"queued"`.

To keep credentials separately and reuse them, skip `upstream` here and use a
slot instead (step 2b). `endpoints.create` **cannot** take a `proxySlotId`.

**2b — Slot-based credentials (optional, reusable).**
`vpn2proxy.slots.create` with `{name, server, port, password, provider?,
username?}`, then `vpn2proxy.endpoints.assign` with `{endpointId, slotId}`.
Passing `slotId: null` unassigns. An endpoint with no slot **fails closed** —
its traffic is blocked rather than leaking direct. Passing `upstream` inline
in step 2 creates a slot for you automatically.

**3 — Wait for the endpoint to go live.** Poll `vpn2proxy.endpoints.list` and
match on `id` until `applyState === "applied"` (watch `applyNote`; `failed`
carries the reason). A missing region host shows as `hostStatus`/`hostStale`.
Requests are queued per region — budget 30–60s, and do not poll faster than
every ~5s.

**4 — Request the device.**

```bash
-d '{"action":"vpn2proxy.devices.request","input":{"endpointId":"…","name":"phone"}}'
```

Returns `{"device":{"id":"…","name":"…"}}` — **the id and name only, never the
profile**. If the endpoint is not `applied` yet this returns **404** with
"This endpoint is not live yet" — the same code as an unknown endpoint, so
check the message and re-poll rather than giving up.

**5 — Wait for the profile, then fetch it.** Poll:

```bash
-d '{"action":"vpn2proxy.devices.profile","input":{"deviceId":"…"}}'
```

- `409` → not provisioned yet; wait and retry. This is the readiness signal.
- `404` → no such device.
- `200` → `{"device":{…},"profile":"<wireguard or openvpn config text>"}`

**6 — Write the config to the device.** `profile` is the raw config: for
WireGuard a `.conf`, for OpenVPN an `.ovpn`. Hand it to the WireGuard/OpenVPN
app, `wg-quick`, or an OpenVPN client.

## Traps

- **`devices.profile` is write-scoped** and is the only action that returns
  credential material. A read-only key gets 403. It is also **one-time**:
  after a short recovery window the sealed copy is wiped and you must call
  `devices.request` again for a new credential. Never log the profile, never
  commit it, never echo it into a transcript.
- **There is no `devices.list`.** You cannot read a device's state directly.
  Poll `devices.profile` and branch on 409 vs 200. `endpoints.list` carries
  no device count either.
- **Two different waits, two different codes** — endpoint liveness is 404 on
  `devices.request`, device provisioning is 409 on `devices.profile`.
- **`endpoints.create` ignores `proxySlotId`.** Use `endpoints.assign`.
- **Admin-only actions** (`health.list`, `fleet.housekeeping`) are always 403
  for API keys, regardless of grants. They need a real admin session.
- **404 also means "unknown action"** — check your spelling before assuming
  the resource is missing.
- **`activity.list` grows with your own calls**; `limit` defaults to 12 and
  caps at 100.
- `endpoints.rotationPlan` is **read** scope and only reports; the write is
  `endpoints.replaceCredential`. A staged credential goes live after the host
  acks it, not immediately.
- Plan limits (endpoints, slots, connections) come from the account's plan,
  not from key grants.

## Reference

`references/actions.md` — every action with required/optional input and
response shape. `scripts/vpn2proxy-api.sh` is a thin authenticated wrapper
that prints `data` on success and exits non-zero on `ok:false`.
