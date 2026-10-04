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

### `data` is not always an object

Every **`*.list` action** returns `data` as a **bare array** —
`regions.list`, `endpoints.list`, `slots.list`, `activity.list`. Every other
action returns `data` as an **object** (`{endpoint}`, `{device}`, …). So code
that assumes `data.get(...)` raises on the list actions, and code that assumes
`for row in data` silently iterates zero times on the object-shaped ones.
Normalise before you parse:

```python
d = env.get("data")
rows = d if isinstance(d, list) else (d.get(key) or d.get("rows") or [])
```

`scripts/vpn2proxy-api.sh` prints `data` raw for exactly this reason — it
cannot know which shape you are about to consume.

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

The echoed row uses **`region`** and **`endpointHost`** — not `regionCode` or
`host`, which are input/join names and are **absent** from the response (a
`KeyError`, not a `null`). `hostStatus` and `hostStale` are present but are
hardcoded `null`/`false` placeholders, because they are host-reported facts the
create path has no way to know yet. So do not validate your input against the
create response, and do not read `endpoint["regionCode"]` — poll
`endpoints.list` (step 3) for the authoritative row.

To keep credentials separately and reuse them, skip `upstream` here and use a
slot instead (step 2b). `endpoints.create` **cannot** take a `proxySlotId`.

**2b — Slot-based credentials (optional, reusable).**
`vpn2proxy.slots.create` with `{name, server, port, password, provider?,
username?}`, then `vpn2proxy.endpoints.assign` with `{endpointId, slotId}`.
Passing `slotId: null` unassigns. An endpoint with no slot **fails closed** —
its traffic is blocked rather than leaking direct. Passing `upstream` inline
in step 2 creates a slot for you automatically.

**3 — Wait for the endpoint to go live.** Poll `vpn2proxy.endpoints.list` and
match on `id` until `applyState === "applied"`. Work is queued per region, so
budget 30–120s and poll no faster than every ~5s.

If it never leaves `queued` for several minutes, the region's host is not
picking work up — check `hostStatus`/`hostStale` on the row and stop rather
than polling forever.

**2c — To change which proxy an endpoint exits through later, update the slot
(`slots.update`), not `endpoints.replaceCredential`** — see the trap list. It
re-queues the endpoints using that slot and the host re-applies (~30–60s).

**3a — If it lands on `failed`, read `applyNote`.** It names the exact cause
and never contains the credential. The overwhelmingly common one is an
**unreachable upstream**, because the host probes the proxy before it will
bring the tunnel up:

```
apply failed on host: error: upstream probe failed, config untouched:
  endpoint-<id> [socks5]: CONNECT=FAIL (gaierror: [Errno -2] Name or service
  not known), UDP: unprobed, 1 ms
```

`gaierror` means the proxy hostname does not resolve; a refused CONNECT or
timeout means the proxy is not reachable or the credentials are wrong. The
host leaves the previous config untouched, so a failed replace never breaks a
working tunnel. Fix the proxy details, then `endpoints.reapply`.

**4 — Request the device.**

```bash
-d '{"action":"vpn2proxy.devices.request","input":{"endpointId":"…","name":"phone"}}'
```

Returns `{"device":{"id":"…","name":"…"}}` — **the id and name only, never the
profile**. If the endpoint is not `applied` yet this returns **404** with
"This endpoint is not live yet" — the same code as an unknown endpoint, so
check the message and re-poll rather than giving up.

**Persist the `deviceId` to disk the moment you get it, before any further
call.** There is no `devices.list`, so a script that crashes between step 4 and
step 6 has no way to recover that id, and the only remedy is provisioning a
brand-new device.

**5 — Wait for the profile, then fetch it.** Poll:

```bash
-d '{"action":"vpn2proxy.devices.profile","input":{"deviceId":"…"}}'
```

- `409` → not provisioned yet; wait and retry. This is the readiness signal.
- `404` → no such device.
- `200` → `{"device":{…},"profile":"<wireguard or openvpn config text>"}`

Budget generously: the region's host applies asynchronously and readiness is
not instant — a WireGuard device has been observed still returning 409 after
100s of 5-second polls. Poll every ~5s and give it at least two minutes before
calling it stuck.

### Branch on the status as a string

If you hand-roll the call with `curl -w '%{http_code}'`, the status comes back
as a **string**. `if code == 200:` is `False` for `"200"`, so a successful
fetch silently falls through to your retry branch and you loop until you give
up — discarding a credential the API handed you correctly, on every iteration.
This is the single most expensive way to use this API:

```python
# WRONG — "200" != 200, every success looks like a failure
if code == 200 and body.get("ok"): ...

# RIGHT
if code == "200" and body.get("ok"): ...
```

Prefer `scripts/vpn2proxy-api.sh`, which already compares
`"$resp" != "200"` and exits non-zero on `ok:false`, so the status never has to
be handled at all:

```bash
./scripts/vpn2proxy-api.sh vpn2proxy.devices.profile '{"deviceId":"…"}' > profile.raw
```

A mis-parsed retry loop does **not** burn the credential: re-polling the same
`deviceId` inside the recovery window keeps returning `200` with the full
profile, so you can recover with the id you already have rather than
provisioning a new device. Do not rely on this though — persist the id.

**6 — Write the config to the device.** `profile` is the raw config: for
WireGuard a `.conf`, for OpenVPN an `.ovpn`. Hand it to the WireGuard/OpenVPN
app, `wg-quick`, or an OpenVPN client.

Write it straight to disk with restrictive permissions and never echo it:

```python
open(path, "w").write(profile); os.chmod(path, 0o600)
```

### The OpenVPN credentials are in COMMENTS — never strip `#` lines

A vpn2proxy OpenVPN profile carries its client auth pair as **comment lines at
the very top**, above the `client` directive:

```bash
# vpn2proxy OpenVPN profile for user: dev-6dfca498
# vpn2proxy-auth-username: dev-6dfca498      <-- username
# vpn2proxy-auth-password: <password>        <-- password
# Enter the username and password in the VPN client's login fields.
client
dev tun
...
auth-user-pass                            <-- BARE: no argument, no file
```

**The single most common way to get this wrong is to filter out `#` lines**
(`grep -v '^#'`, dropping "comments", an INI parser that discards them). That
throws away the only place the credentials exist, and you will confidently
report that the profile has no credentials. It does. Do not strip comments
before searching for `# vpn2proxy-auth-`.

Two more things that disguise the payload:

- **`auth-user-pass` is bare.** It has no inline argument and no file
  reference, so OpenVPN prompts interactively instead of reading the profile.
  Inspecting the directive shows no credentials — that is expected, not
  evidence of absence. (The generator ships the pair in comments precisely
  because router clients expect a bare `auth-user-pass`.)
- **The `#` lines come before `client`.** A "first line" check misses them.

Extract them:

```python
u  = re.search(r'^# vpn2proxy-auth-username: (.+)$', p, re.M).group(1).strip()
pw = re.search(r'^# vpn2proxy-auth-password: (.+)$', p, re.M).group(1).strip()
```

To make the profile self-contained, rewrite the bare directive into the inline
block — this is exactly what the dashboard's "Embed credentials" toggle does:

```
<auth-user-pass>
<username>
<password>
</auth-user-pass>
```

Older sealed profiles already use the inline `<auth-user-pass>…</auth-user-pass>`
form, so support both shapes when parsing.

### Telling OpenVPN and WireGuard profiles apart

An OpenVPN profile's **first non-comment line is `client`**; a WireGuard
profile starts with `[Interface]`. That is the reliable discriminator — but
apply it to the first *non-comment* line, or the four leading `#` lines will
make you misread an OpenVPN profile as unrecognisable.

Do not discriminate by port: an OpenVPN profile uses port **51821**, which
resembles a WireGuard port but is a real OpenVPN endpoint. Do not require an
inline `<auth-user-pass>` either — see above. Certificate blocks
(`-----BEGIN`, four of them) and `remote-cert-tls server` are good corroboration.

## Traps

- **`devices.profile` is write-scoped** and is the only action that returns
  credential material. A read-only key gets 403. The sealed copy is eventually
  wiped (a "recovery window" after which you must call `devices.request` again
  for a new credential), but **re-reading it does not consume it** — repeated
  200s inside that window each return the full profile. Never log the profile,
  never commit it, never echo it into a transcript. Write it with `0600`.
- **The OpenVPN auth pair lives in `#` comment lines at the top of the profile.**
  Stripping comments (or trusting the bare `auth-user-pass` directive) hides the
  only copy of the username and password. Always search the raw text for
  `# vpn2proxy-auth-username:` / `# vpn2proxy-auth-password:` — see
  "The OpenVPN credentials are in COMMENTS" above. This has caused a real
  agent to report a profile had no credentials when it had both.
- **OpenVPN profiles start with `client`** (after those comments); WireGuard
  profiles start with `[Interface]`. Check the first non-comment line, and
  never discriminate on the port — OpenVPN's is 51821.
- **Comparing `curl -w '%{http_code}'` to an int silently loses a good
  credential.** See "Branch on the status as a string" above — prefer the
  wrapper script.
- **`endpoints.create` echoes a sparse row** with `regionCode`/`host`/
  `hostStatus` as `null` even on success. Poll `endpoints.list` for truth.
- **`data` is an array for `regions.list` and an object elsewhere.** See
  "`data` is not always an object" above.
- **There is no `devices.list`.** You cannot read a device's state directly.
  Poll `devices.profile` and branch on 409 vs 200. `endpoints.list` carries
  no device count either. Persist `deviceId` before you poll.
- **Two different waits, two different codes** — endpoint liveness is 404 on
  `devices.request`, device provisioning is 409 on `devices.profile`.
- **`endpoints.create` ignores `proxySlotId`.** Use `endpoints.assign`.
- **Rotating an endpoint's upstream: update the SLOT, not the endpoint.** If the
  endpoint has a slot assigned, `endpoints.replaceCredential` is **refused (400)**
  — the host reads the slot in preference to the endpoint's own credential, so an
  endpoint-scoped replacement would be silently ignored. `slots.update` is the
  supported path: it re-queues every endpoint using that slot and wakes the
  region, and returns `requeuedEndpoints`. Because one slot can serve many
  endpoints, editing the slot is also the honest blast radius.
- **Admin-only actions** (`health.list`, `fleet.housekeeping`) are always 403
  for API keys, regardless of grants. They need a real admin session.
- **404 also means "unknown action"** — check your spelling before assuming
  the resource is missing.
- **`activity.list` grows with your own calls**; `limit` defaults to 12 and
  caps at 100.
- `endpoints.rotationPlan` is **read** scope and only reports; the write is
  `endpoints.replaceCredential`. A staged credential goes live after the host
  acks it, not immediately.
- **The host probes your upstream before bringing the tunnel up**, so an
  unreachable or unresolvable proxy is the most common reason an endpoint
  lands on `failed`. `applyNote` says which.
- **There is no endpoint-removal action.** Removal and revocation of
  provisioned devices are dashboard operations; the API covers create, read,
  update, and reassign.
- Plan limits (endpoints, slots, connections) come from the account's plan,
  not from key grants.

## Reference

`references/actions.md` — every action with required/optional input and
response shape. `scripts/vpn2proxy-api.sh` is a thin authenticated wrapper
that prints `data` on success and exits non-zero on `ok:false`.
