# MCP Zoo

A small, private, self-hosted gateway for [MCP](https://modelcontextprotocol.io) (Model Context Protocol) servers. Each stdio-based MCP server is wrapped by [supergateway](https://github.com/supercorp-ai/supergateway) and exposed over Streamable HTTP, with **nginx** as the single entry point enforcing per-server token auth via the `X-MCP-PROXY-PASS` header (the deployment environment strips `Authorization` headers, so HTTP Basic auth cannot be used).

Currently wrapped: the [Mealie MCP server](https://github.com/rldiao/mealie-mcp-server) at `/mealie` and the [AnyList MCP server](https://github.com/davidashman/anylist-mcp) at `/anylist`.

## Architecture

```
client ──(X-MCP-PROXY-PASS: <token>)──▶ nginx:48080/<name> ──▶ <name>-mcp:8000/mcp (supergateway) ──stdio──▶ MCP server
```

- **nginx** is the only exposed port (`48080`). Wrapper containers publish no ports.
- Each wrapped server has its **own token** — one token file (`auth/<name>.tokens`) per server.
- nginx verifies the `X-MCP-PROXY-PASS` token, then strips it (and any `Authorization` header) before proxying; wrapped servers never see gateway credentials.
- Responses may be SSE-formatted (`data: {...}` lines) — that's normal for Streamable HTTP.

## Prerequisites

- Docker with Compose plugin
- A running [Mealie](https://github.com/mealie-recipes/mealie) instance (or another MCP server you want to wrap)
- Mealie API token (Settings → API Tokens in Mealie)
- An [AnyList](https://www.anylist.com/) account (email + password)

## Quick start

1. **Configure environment**

   ```bash
   cp .env.example .env
   # Edit .env and set MEALIE_BASE_URL, MEALIE_API_KEY, ANYLIST_EMAIL, ANYLIST_PASSWORD
   ```

2. **Create a gateway token**

   ```bash
   bash add-auth.sh mealie
   ```

   Save the printed `X-MCP-PROXY-PASS` header — it is shown only once.

3. **Start the stack**

   ```bash
   docker compose up -d --build
   ```

4. **Smoke test**

   ```bash
   curl -H "X-MCP-PROXY-PASS: <token>" -X POST http://localhost:48080/mealie \
     -H "Content-Type: application/json" \
     -H "Accept: application/json, text/event-stream" \
     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
   ```

   Expected: no token → `401`; unknown path → `404`; valid token → MCP `initialize` result.

## Connecting an MCP client

Point your MCP client at:

```
URL:      http://<host>:48080/mealie     # Mealie
          http://<host>:48080/anylist   # AnyList
Header:   X-MCP-PROXY-PASS: <token from add-auth.sh>
```

If the client supports custom headers, send:

```
X-MCP-PROXY-PASS: <token>
Accept: application/json, text/event-stream
```

## Configuration

### Environment variables (`.env`)

| Variable | Required | Description |
|---|---|---|
| `MEALIE_BASE_URL` | Yes | Base URL of your Mealie instance (e.g. `https://mealie.example.com`) |
| `MEALIE_API_KEY` | Yes | Mealie API token |
| `MEALIE_MCP_SOURCE` | No | Pin the Mealie MCP server to a specific commit: `git+https://github.com/rldiao/mealie-mcp-server@<sha>` |
| `ANYLIST_EMAIL` | Yes | AnyList account email |
| `ANYLIST_PASSWORD` | Yes | AnyList account password |

### Restricting to localhost

Edit `docker-compose.yml` and change the nginx port mapping:

```yaml
ports:
  - "127.0.0.1:48080:48080"
```

## Adding a new MCP server

1. **Dockerfile** — add `Dockerfile.<name>`: `node:22-slim` + git + `npm install -g supergateway`, then install/build the wrapped server (for the TypeScript AnyList server: clone the repo, `npm install && npm run build`).

2. **Compose** — add a `<name>-mcp` service to `docker-compose.yml`:

   ```yaml
   <name>-mcp:
     build:
       context: .
       dockerfile: Dockerfile.<name>
     restart: unless-stopped
     security_opt:
       - no-new-privileges:true
     command:
       - --stdio
       - "<command to run the MCP server>"
       - --outputTransport
       - streamableHttp
       - --port
       - "8000"
       - --streamableHttpPath
       - /mcp
       - --stateful
       - --sessionTimeout
       - "600000"
     environment:
       VAR_NAME: ${VAR_NAME:?set VAR_NAME in .env}
     # No ports published.
   ```

   If the Dockerfile has no `ENTRYPOINT`, prefix the command with `supergateway`. For the AnyList server ([davidashman/anylist-mcp](https://github.com/davidashman/anylist-mcp)) the stdio command is `node dist/index.js` and the secrets are `ANYLIST_EMAIL` / `ANYLIST_PASSWORD`. The existing `anylist-mcp` service predates some of these conventions (no `security_opt`, no `--streamableHttpPath`/`--sessionTimeout`, runs as root) — align it when convenient.

3. **nginx** — copy `nginx/locations/mealie.conf` to `nginx/locations/<name>.conf`, and update:
   - `location = /<name>`
   - `if ($<name>_token_ok = 0) { return 401; }`
   - `set $upstream "<name>-mcp:8000"`
   Also add a `map $http_x_mcp_proxy_pass $<name>_token_ok { default 0; include /etc/nginx/auth/<name>.tokens; }` block to `nginx/nginx.conf`.

4. **Auth** — create the token:

   ```bash
   bash add-auth.sh <name>
   ```

   Reload nginx so it reads the new token file: `docker compose exec nginx nginx -s reload`.

5. **Env** — add any new variables to `.env.example` (placeholders only).

6. **Reload and verify**:

   ```bash
   docker compose up -d
   docker compose exec nginx nginx -s reload
   # Run the smoke test against /<name>
   ```

## Common commands

```bash
docker compose up -d --build        # start / rebuild
docker compose logs -f mealie-mcp   # wrapper logs (first place to look when something fails)
docker compose logs -f nginx
docker compose exec nginx nginx -t  # validate nginx config
docker compose restart nginx        # pick up new/changed location files and token files
bash add-auth.sh <name> [--add]     # create or rotate a token (prints the header once)
```

## Security notes

- **The `X-MCP-PROXY-PASS` token over plain HTTP** is sent in clear text. Keep this on localhost or a trusted VPN. For remote access, add TLS (nginx certificate, or put Caddy / Tailscale Serve in front).
- **Never commit** `.env` or `auth/` — both are gitignored.
- **One token per server** — don't share token files across servers. Token files are plaintext secrets; keep them `chmod 600` inside the gitignored `auth/` directory.
- Wrapper containers publish no ports. `no-new-privileges` is set on the Mealie wrapper; the AnyList wrapper does not set it yet.
- nginx strips the `X-MCP-PROXY-PASS` header (and any `Authorization` header) before proxying to the wrapped server.

## Troubleshooting

| Symptom | Check |
|---|---|
| `401 Unauthorized` | Wrong or missing `X-MCP-PROXY-PASS` token, or `auth/<name>.tokens` missing. Re-run `add-auth.sh`, then reload nginx (`docker compose exec nginx nginx -s reload`). |
| `404 Not Found` | Wrong path, or `nginx/locations/<name>.conf` not mounted. Restart nginx. |
| `502 Bad Gateway` | Wrapper container is down or crashing. Check `docker compose logs -f <name>-mcp`. |
| Wrapper exits at start | Check `supergateway --help` flags; verify the stdio command runs. |
| No data from Mealie | Verify `MEALIE_BASE_URL` and `MEALIE_API_KEY` in `.env`; check wrapper logs. |
| No data from AnyList | Verify `ANYLIST_EMAIL` and `ANYLIST_PASSWORD` in `.env`; check wrapper logs (`docker compose logs -f anylist-mcp`). |
| nginx won't start | Run `docker compose exec nginx nginx -t` to validate config. |

## Project layout

```
docker-compose.yml           # one supergateway service per wrapped server, plus nginx
.env.example                 # template for .env (secrets); .env itself is never committed
add-auth.sh                  # creates/rotates auth/<name>.tokens and prints the X-MCP-PROXY-PASS header once
Dockerfile.<name>            # one image per wrapped server (Dockerfile.mealie, Dockerfile.anylist)
nginx/nginx.conf             # main nginx config; includes nginx/locations/*.conf
nginx/locations/<name>.conf  # one location block per wrapped server
auth/                        # generated token files (gitignored, mounted read-only into nginx)
AGENTS.md                    # guidance for AI coding agents working in this repo
```

## License

Private use. See individual upstream projects for their licenses:
- [supergateway](https://github.com/supercorp-ai/supergateway)
- [mealie-mcp-server](https://github.com/rldiao/mealie-mcp-server)
- [Mealie](https://github.com/mealie-recipes/mealie)
- [anylist-mcp](https://github.com/davidashman/anylist-mcp)
- [AnyList](https://www.anylist.com/)
