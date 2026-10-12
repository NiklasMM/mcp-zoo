# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this project is

A small, private, self-hosted gateway for MCP (Model Context Protocol) servers, run with Docker Compose.

- Each **stdio-based MCP server** is wrapped by [supergateway](https://github.com/supercorp-ai/supergateway) so it is reachable over **Streamable HTTP**.
- **nginx** is the single public entry point (port `48080`). It routes by path (`/<name>`) to the matching wrapper and enforces **HTTP Basic auth, with a separate credential per wrapped server**.
- Currently wrapped: the Mealie MCP server (`https://github.com/rldiao/mealie-mcp-server`) at `/mealie`, and the AnyList MCP server (`https://github.com/davidashman/anylist-mcp`) at `/anylist`.

This is for one person's private use. Prefer simple, auditable solutions over feature-rich ones. Do not introduce a heavy gateway or orchestration layer unless asked.

## Layout

```
docker-compose.yml           # one supergateway service per wrapped server, plus nginx
.env.example                 # template for .env (secrets); .env itself is never committed
add-auth.sh                  # creates/rotates auth/<name>.htpasswd and prints the credential once
Dockerfile.<name>            # one image per wrapped server (Dockerfile.mealie, Dockerfile.anylist):
                             # node + git + supergateway, with the wrapped server installed at build time
nginx/nginx.conf             # main nginx config; includes nginx/locations/*.conf
nginx/locations/<name>.conf  # one location block per wrapped server
auth/                        # generated htpasswd files (gitignored, mounted read-only into nginx)
```

## How requests flow

```
client --(Basic auth)--> nginx:48080/<name> --> <name>-mcp:8000/mcp (supergateway) --stdio--> MCP server process
```

- nginx strips the `Authorization` header before proxying; wrapped servers never see the gateway credential.
- Wrapper containers publish **no ports**. Only nginx is reachable from outside the Docker network.
- nginx resolves upstreams per request (`resolver 127.0.0.11` plus a `set $upstream` variable), so it still starts if a wrapper is down.

## Common commands

```bash
docker compose up -d --build        # start / rebuild
docker compose logs -f mealie-mcp   # wrapper logs (first place to look when something fails)
docker compose logs -f nginx
docker compose exec nginx nginx -t  # validate nginx config
docker compose restart nginx        # pick up new/changed location files
bash add-auth.sh <name> [user]      # create or rotate a credential (prints it once)
```

Smoke test (replace the credential):

```bash
curl -u <user>:<password> -X POST http://localhost:48080/<name> \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

Expected: no credentials gives `401`; an unknown path gives `404`; valid credentials give an MCP `initialize` result. Responses may be SSE-formatted (`data: {...}` lines). That is normal for Streamable HTTP.

## Adding a wrapped server

Follow this checklist exactly so the conventions stay consistent:

1. **Dockerfile:** add `Dockerfile.<name>` — `node:22-slim` + git + `npm install -g supergateway`, then install/build the wrapped server (the TypeScript anylist-mcp: clone the repo, `npm install && npm run build`). Mealie's image additionally gets uv/uvx and runs as the `node` user with `ENTRYPOINT ["supergateway"]`.
2. **Compose:** add a service named `<name>-mcp` with `build: { context: ., dockerfile: Dockerfile.<name> }`. Set `--stdio "<command>"`, `--outputTransport streamableHttp`, `--port 8000`, `--streamableHttpPath /mcp`, plus the `--stateful` flags used by the existing services. Pass its secrets via `environment:` from `.env` using `${VAR:?message}`. Do **not** publish ports. For anylist-mcp the stdio command is `node dist/index.js` (from the app dir) and the secrets are `ANYLIST_EMAIL` / `ANYLIST_PASSWORD`.
3. **nginx:** copy `nginx/locations/mealie.conf` to `nginx/locations/<name>.conf`; change the location path, the htpasswd filename, and the upstream host name. Use an exact-match `location = /<name>`.
4. **Auth:** run `bash add-auth.sh <name>` and give the printed credential to the user. Never invent, log, or commit credentials.
5. **Env:** add any new variables to `.env.example` (placeholders only).
6. Restart nginx, run the smoke test, and confirm 401 without credentials and that one server's credential does **not** work on another server's path.

Note: the existing `anylist-mcp` service predates some of these conventions (no `security_opt`, no `--streamableHttpPath`/`--sessionTimeout`, runs as root, unpinned supergateway, and `ANYLIST_MCP_REF` is declared but unused). Align it when convenient.

## Rules and constraints

- **Never commit** `.env` or `auth/`. Keep both in `.gitignore`.
- **Never publish wrapper ports** or bind them to the host. nginx is the only entry point.
- **Keep per-server credentials separate.** One htpasswd file per server; do not share users across servers.
- **Keep `proxy_set_header Authorization ""`** in every location block.
- **Keep streaming settings** in location blocks (`proxy_buffering off`, `proxy_http_version 1.1`, `Connection ""`, long read timeouts). Buffering breaks MCP streaming responses.
- **Pin versions** when asked to harden: `SUPERGATEWAY_VERSION` build arg, the `uv` image tag in the Dockerfile, the Mealie MCP source via `MEALIE_MCP_SOURCE=git+https://...@<commit-sha>`, and the AnyList MCP source via `ANYLIST_MCP_REF` in `Dockerfile.anylist` (the arg is currently declared but unused — the clone hardcodes `main`; wire it into the clone/checkout when hardening). The wrapper container holds real API keys and exposes write-capable tools, so avoid unpinned third-party code where practical.
- Prefer well-maintained, source-visible dependencies. A stdio-to-HTTP wrapper previously considered (`mcp-streamablehttp-proxy`) was rejected because it has had no release in over a year and its repository is gone. Check release dates and repo activity before adding any new wrapper or proxy.
- Basic auth over plain HTTP sends credentials in clear text. If the user exposes this beyond localhost/VPN, add TLS (nginx certificate, or Caddy / Tailscale Serve in front) rather than weakening anything else.

## Verified end to end (2026-10-12, against `/anylist`)

- nginx per-server basic auth works: `401` without credentials, `404` on an unknown path, `200` with the correct credential.
- `--outputTransport streamableHttp` selects Streamable HTTP output as expected: `initialize` returns an SSE (`data: {...}`) response plus an `mcp-session-id` header; follow-up requests (`notifications/initialized` → `202`, `tools/list`, `tools/call`) sent with that session id work.
- supergateway does not reject the default `Host` header (no 403s through nginx).
- The anylist service omits `--streamableHttpPath`, so supergateway's default path is `/mcp` — matching the nginx `proxy_pass .../mcp`.
- `--stateful` keeps one stdio process per `mcp-session-id`; sequential `tools/call`s in one session reuse the same AnyList connection.
- The AnyList server (davidashman/anylist-mcp, run as `node dist/index.js`) was exercised with real credentials: `get_lists`, `get_recipes`, `get_meal_plan`, and `get_list_items` all returned live account data. It reads `ANYLIST_EMAIL` / `ANYLIST_PASSWORD` from the container environment.

## Known uncertainties (verify before relying on them)

These were written from documentation snippets and memory; the Mealie half of the stack has not been run end to end yet:

- Stateless mode (without `--stateful`) may spawn a new stdio process per request (slow with `uvx`). Not confirmed either way. Idle sessions expire after `--sessionTimeout` (10 minutes); clients should re-initialize.
- The Mealie process is expected to inherit `MEALIE_BASE_URL` and `MEALIE_API_KEY` from the container environment. Confirm with a `tools/call` that returns real Mealie data.
- The Mealie server's tool names and startup command (`uvx git+https://github.com/rldiao/mealie-mcp-server`) come from its README; check the README again if startup fails.
- nginx is expected to re-read `auth/*.htpasswd` on each request, so credential rotation should not need a reload. Confirm.

When you resolve one of these, update this section to say what was verified and how.

## Possible next steps

- Run the Mealie half of the stack end to end and record the verified behavior above (the AnyList half is verified — see above).
- Add the pinning described under Rules.
- Add TLS if remote access is needed.
- Add `limit_req` (or fail2ban) for failed-login throttling if the port is exposed beyond a trusted network.
- Optionally add a merged-tools aggregator in front of the wrappers. This is only worth it if per-agent URLs become annoying.
