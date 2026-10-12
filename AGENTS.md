# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this project is

A small, private, self-hosted gateway for MCP (Model Context Protocol) servers, run with Docker Compose.

- Each **stdio-based MCP server** is wrapped by [supergateway](https://github.com/supercorp-ai/supergateway) so it is reachable over **Streamable HTTP**.
- **nginx** is the single public entry point (port `48080`). It routes by path (`/<name>`) to the matching wrapper and enforces **HTTP Basic auth, with a separate credential per wrapped server**.
- Currently wrapped: the Mealie MCP server (`https://github.com/rldiao/mealie-mcp-server`), served at `/mealie`.

This is for one person's private use. Prefer simple, auditable solutions over feature-rich ones. Do not introduce a heavy gateway or orchestration layer unless asked.

## Layout

```
docker-compose.yml           # one supergateway service per wrapped server, plus nginx
.env.example                 # template for .env (secrets); .env itself is never committed
add-auth.sh                  # creates/rotates auth/<name>.htpasswd and prints the credential once
supergateway/Dockerfile      # shared image: node + git + uv/uvx + supergateway
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

1. **Compose:** add a service named `<name>-mcp` that reuses `image: mcp-supergateway:local` (do not add a second `build:`). Set `--stdio "<command>"`, `--outputTransport streamableHttp`, `--port 8000`, `--streamableHttpPath /mcp`, plus the `--stateful` flags used by the existing service. Pass its secrets via `environment:` from `.env` using `${VAR:?message}`. Do **not** publish ports.
2. **nginx:** copy `nginx/locations/mealie.conf` to `nginx/locations/<name>.conf`; change the location path, the htpasswd filename, and the upstream host name. Use an exact-match `location = /<name>`.
3. **Auth:** run `bash add-auth.sh <name>` and give the printed credential to the user. Never invent, log, or commit credentials.
4. **Env:** add any new variables to `.env.example` (placeholders only).
5. Restart nginx, run the smoke test, and confirm 401 without credentials and that one server's credential does **not** work on another server's path.

## Rules and constraints

- **Never commit** `.env` or `auth/`. Keep both in `.gitignore`.
- **Never publish wrapper ports** or bind them to the host. nginx is the only entry point.
- **Keep per-server credentials separate.** One htpasswd file per server; do not share users across servers.
- **Keep `proxy_set_header Authorization ""`** in every location block.
- **Keep streaming settings** in location blocks (`proxy_buffering off`, `proxy_http_version 1.1`, `Connection ""`, long read timeouts). Buffering breaks MCP streaming responses.
- **Pin versions** when asked to harden: `SUPERGATEWAY_VERSION` build arg, the `uv` image tag in the Dockerfile, and the Mealie MCP source via `MEALIE_MCP_SOURCE=git+https://...@<commit-sha>`. The wrapper container holds real API keys and exposes write-capable tools, so avoid unpinned third-party code where practical.
- Prefer well-maintained, source-visible dependencies. A stdio-to-HTTP wrapper previously considered (`mcp-streamablehttp-proxy`) was rejected because it has had no release in over a year and its repository is gone. Check release dates and repo activity before adding any new wrapper or proxy.
- Basic auth over plain HTTP sends credentials in clear text. If the user exposes this beyond localhost/VPN, add TLS (nginx certificate, or Caddy / Tailscale Serve in front) rather than weakening anything else.

## Known uncertainties (verify before relying on them)

These were written from documentation snippets and memory, and **the stack has not been run end to end yet**:

- `--outputTransport streamableHttp` is the supergateway flag believed to select Streamable HTTP output. Confirm against `supergateway --help` for the installed version. If the wrapper container exits at start, check its logs first.
- `--stateful` is used so one stdio process lives per session. Stateless mode may spawn a new process per request (slow with `uvx`). Not confirmed either way. Idle sessions expire after `--sessionTimeout` (10 minutes); clients should re-initialize.
- The Mealie process is expected to inherit `MEALIE_BASE_URL` and `MEALIE_API_KEY` from the container environment. Confirm with a `tools/call` that returns real Mealie data.
- The Mealie server's tool names and startup command (`uvx git+https://github.com/rldiao/mealie-mcp-server`) come from its README; check the README again if startup fails.
- nginx is expected to re-read `auth/*.htpasswd` on each request, so credential rotation should not need a reload. Confirm.
- Whether supergateway rejects unexpected `Host` headers. The nginx config does not override `Host`, so the default (the upstream's own host:port) is used. If you see 403s from the wrapper, investigate this.

When you resolve one of these, update this section to say what was verified and how.

## Possible next steps

- Run the stack end to end and record the verified behavior above.
- Add the pinning described under Rules.
- Add TLS if remote access is needed.
- Add `limit_req` (or fail2ban) for failed-login throttling if the port is exposed beyond a trusted network.
- Optionally add a merged-tools aggregator in front of the wrappers. This is only worth it if per-agent URLs become annoying.
