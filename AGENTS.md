# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this project is

A small, private, self-hosted gateway for MCP (Model Context Protocol) servers, run with Docker Compose.

- Each **stdio-based MCP server** is wrapped by [supergateway](https://github.com/supercorp-ai/supergateway) so it is reachable over **Streamable HTTP**.
- **nginx** is the single public entry point (port `48080`). It routes by path (`/<name>`) to the matching wrapper and enforces **token auth via the `X-MCP-PROXY-PASS` header, with a separate token per wrapped server** (the deployment environment strips `Authorization` headers, so HTTP Basic auth cannot be used).
- Currently wrapped: the Mealie MCP server (`https://github.com/rldiao/mealie-mcp-server`) at `/mealie`, and the AnyList MCP server (`https://github.com/bobby060/anylist-mcp`) at `/anylist`.

This is for one person's private use. Prefer simple, auditable solutions over feature-rich ones. Do not introduce a heavy gateway or orchestration layer unless asked.

## Layout

```
docker-compose.yml           # one supergateway service per wrapped server, plus nginx
.env.example                 # template for .env (secrets); .env itself is never committed
add-auth.sh                  # creates/rotates auth/<name>.tokens and prints the X-MCP-PROXY-PASS header once
Dockerfile.<name>            # one image per wrapped server (Dockerfile.mealie, Dockerfile.anylist):
                             # node + git + supergateway, with the wrapped server installed at build time
nginx/nginx.conf             # main nginx config; includes nginx/locations/*.conf
nginx/locations/<name>.conf  # one location block per wrapped server
auth/                        # generated token files (gitignored, mounted read-only into nginx)
```

## How requests flow

```
client --(X-MCP-PROXY-PASS: <token>)--> nginx:48080/<name> --> <name>-mcp:8000/mcp (supergateway) --stdio--> MCP server process
```

- nginx checks the `X-MCP-PROXY-PASS` token against `auth/<name>.tokens` (via the `map` blocks in `nginx/nginx.conf`), then strips that header — and any `Authorization` header — before proxying; wrapped servers never see the gateway credential.
- Wrapper containers publish **no ports**. Only nginx is reachable from outside the Docker network.
- nginx resolves upstreams per request (`resolver 127.0.0.11` plus a `set $upstream` variable), so it still starts if a wrapper is down.

## Common commands

```bash
docker compose up -d --build        # start / rebuild
docker compose logs -f mealie-mcp   # wrapper logs (first place to look when something fails)
docker compose logs -f nginx
docker compose exec nginx nginx -t  # validate nginx config
docker compose restart nginx        # pick up new/changed location files and token files
bash add-auth.sh <name> [--add]     # create or rotate a token (prints the header once)
```

Smoke test (replace the token):

```bash
curl -H "X-MCP-PROXY-PASS: <token>" -X POST http://localhost:48080/<name> \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
```

Expected: no token gives `401`; an unknown path gives `404`; a valid token gives an MCP `initialize` result. Responses may be SSE-formatted (`data: {...}` lines). That is normal for Streamable HTTP.

## Adding a wrapped server

Follow this checklist exactly so the conventions stay consistent:

1. **Dockerfile:** add `Dockerfile.<name>` — `node:22-slim` + git + `npm install -g supergateway`, then install/build the wrapped server (anylist-mcp is plain JS: clone with `--recurse-submodules`, `npm ci --omit=dev`, no build step). Mealie's image additionally gets uv/uvx and runs as the `node` user with `ENTRYPOINT ["supergateway"]`.
2. **Compose:** add a service named `<name>-mcp` with `build: { context: ., dockerfile: Dockerfile.<name> }`. Set `--stdio "<command>"`, `--outputTransport streamableHttp`, `--port 8000`, `--streamableHttpPath /mcp`, plus the `--stateful` flags used by the existing services. Pass its secrets via `environment:` from `.env` using `${VAR:?message}`. Do **not** publish ports. For anylist-mcp the stdio command is `node src/server.js` (from the app dir) and the secrets are `ANYLIST_USERNAME` / `ANYLIST_PASSWORD` / `ANYLIST_LIST_NAME` (the last is the default list for calls that omit `list_name`; the server errors on such calls when it is unset or names a list that doesn't exist).
3. **nginx:** copy `nginx/locations/mealie.conf` to `nginx/locations/<name>.conf`; change the location path, the token-map variable (`$<name>_token_ok`), and the upstream host name. Use an exact-match `location = /<name>`. Also add a `map $http_x_mcp_proxy_pass $<name>_token_ok { default 0; include /etc/nginx/auth/<name>.tokens; }` block to `nginx/nginx.conf`.
4. **Auth:** run `bash add-auth.sh <name>` and give the printed `X-MCP-PROXY-PASS` header to the user. Never invent, log, or commit credentials. Reload nginx so the new token file is read: `docker compose exec nginx nginx -s reload`.
5. **Env:** add any new variables to `.env.example` (placeholders only).
6. Reload nginx, run the smoke test, and confirm 401 without a token and that one server's token does **not** work on another server's path.

Note: the `anylist-mcp` service was aligned with these conventions on 2026-10-12 while swapping in bobby060/anylist-mcp (`security_opt`, `--streamableHttpPath`/`--sessionTimeout`, non-root `node` user, supergateway pinned to 4.1.0, `ANYLIST_MCP_REF` wired into the clone/checkout and pinned by default).

## Rules and constraints

- **Never commit** `.env` or `auth/`. Keep both in `.gitignore`.
- **Never publish wrapper ports** or bind them to the host. nginx is the only entry point.
- **Keep per-server credentials separate.** One token file (`auth/<name>.tokens`) per server; do not share tokens across servers. Token files are plaintext secrets: keep them `chmod 600` inside the gitignored `auth/` directory.
- **Keep `proxy_set_header Authorization ""` and `proxy_set_header X-MCP-PROXY-PASS ""`** in every location block.
- **Keep streaming settings** in location blocks (`proxy_buffering off`, `proxy_http_version 1.1`, `Connection ""`, long read timeouts). Buffering breaks MCP streaming responses.
- **Pin versions** when asked to harden: `SUPERGATEWAY_VERSION` build arg, the `uv` image tag in the Dockerfile, the Mealie MCP source via `MEALIE_MCP_SOURCE=git+https://...@<commit-sha>`, and the AnyList MCP source via `ANYLIST_MCP_REF` in `Dockerfile.anylist` (wired into the clone/checkout and pinned to a commit by default; mealie's image still defaults to `SUPERGATEWAY_VERSION=latest` and the `uv:latest` tag). The wrapper container holds real API keys and exposes write-capable tools, so avoid unpinned third-party code where practical.
- Prefer well-maintained, source-visible dependencies. A stdio-to-HTTP wrapper previously considered (`mcp-streamablehttp-proxy`) was rejected because it has had no release in over a year and its repository is gone. Check release dates and repo activity before adding any new wrapper or proxy.
- The `X-MCP-PROXY-PASS` token is sent in clear text over plain HTTP. If the user exposes this beyond localhost/VPN, add TLS (nginx certificate, or Caddy / Tailscale Serve in front) rather than weakening anything else.

## Verified end to end (2026-10-12, against `/anylist`)

- Auth mechanism changed 2026-10-12: Basic auth replaced by per-server `X-MCP-PROXY-PASS` tokens (the deployment environment strips `Authorization` headers). Expected behavior is unchanged — `401` without a token, `404` on an unknown path, `200` with the correct token — but re-run the smoke test to re-verify.
- `--outputTransport streamableHttp` selects Streamable HTTP output as expected: `initialize` returns an SSE (`data: {...}`) response plus an `mcp-session-id` header; follow-up requests (`notifications/initialized` → `202`, `tools/list`, `tools/call`) sent with that session id work.
- supergateway does not reject the default `Host` header (no 403s through nginx).
- `--stateful` keeps one stdio process per `mcp-session-id`; sequential `tools/call`s in one session reuse the same AnyList connection.
- The AnyList server was swapped 2026-10-12 from davidashman/anylist-mcp to bobby060/anylist-mcp (pinned at commit `60763f6`, run as `node src/server.js`). Verified over stdio with real credentials: `initialize`, `tools/list` (5 grouped tools: `health_check`, `shopping`, `recipes`, `meal_plan`, `recipe_collections`), `health_check`, `shopping` → `list_lists`, and `shopping` → `list_items` with an explicit `list_name` all returned live account data. It reads `ANYLIST_USERNAME` / `ANYLIST_PASSWORD` / `ANYLIST_LIST_NAME` from the container environment.
- Despite its README, bobby060/anylist-mcp has **no** built-in "Groceries" default: a shopping call that omits `list_name` fails with `No list name provided and no default list configured` when `ANYLIST_LIST_NAME` is unset — and even `shopping` → `list_lists` goes through the same check, so the variable must name a list that exists. It is only a fallback: a per-call `list_name` always wins, and the server works across all lists.
- With `ANYLIST_LIST_NAME` set but multiple lists in the account, `shopping` → `list_items` without `list_name` attempts interactive elicitation ("Which list?"); clients without elicitation support get a clean error asking for `list_name`. Agents should pass `list_name` explicitly.
- The old flat tool names (`get_lists`, `get_list_items`, `get_recipes`, `get_meal_plan`, …) are gone; call sites must use the grouped tools with an `action` parameter.
- The anylist service now sets `--streamableHttpPath /mcp` explicitly (same as the supergateway default it had before), matching the nginx `proxy_pass .../mcp`.

## Known uncertainties (verify before relying on them)

These were written from documentation snippets and memory; the Mealie half of the stack has not been run end to end yet:

- Stateless mode (without `--stateful`) may spawn a new stdio process per request (slow with `uvx`). Not confirmed either way. Idle sessions expire after `--sessionTimeout` (10 minutes); clients should re-initialize.
- The Mealie process is expected to inherit `MEALIE_BASE_URL` and `MEALIE_API_KEY` from the container environment. Confirm with a `tools/call` that returns real Mealie data.
- The Mealie server's tool names and startup command (`uvx git+https://github.com/rldiao/mealie-mcp-server`) come from its README; check the README again if startup fails.
- Token rotation needs an nginx reload: `auth/<name>.tokens` is `include`d by a `map` at config-load time, not read per request like htpasswd was. After `add-auth.sh`, run `docker compose exec nginx nginx -s reload`.

When you resolve one of these, update this section to say what was verified and how.

## Possible next steps

- Run the Mealie half of the stack end to end and record the verified behavior above (the AnyList half is verified — see above).
- Finish the pinning described under Rules for the mealie image (`SUPERGATEWAY_VERSION`, the `uv` tag, `MEALIE_MCP_SOURCE`); the anylist image is already pinned.
- Add TLS if remote access is needed.
- Add `limit_req` (or fail2ban) for failed-login throttling if the port is exposed beyond a trusted network.
- Optionally add a merged-tools aggregator in front of the wrappers. This is only worth it if per-agent URLs become annoying.
