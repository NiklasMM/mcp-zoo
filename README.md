# MCP Zoo

A small, private, self-hosted gateway for [MCP](https://modelcontextprotocol.io) (Model Context Protocol) servers. Each stdio-based MCP server is wrapped by [supergateway](https://github.com/supercorp-ai/supergateway) and exposed over Streamable HTTP, with **nginx** as the single entry point enforcing per-server HTTP Basic auth.

Currently wrapped: the [Mealie MCP server](https://github.com/rldiao/mealie-mcp-server) at `/mealie`.

## Architecture

```
client ──(Basic auth)──▶ nginx:48080/<name> ──▶ <name>-mcp:8000/mcp (supergateway) ──stdio──▶ MCP server
```

- **nginx** is the only exposed port (`48080`). Wrapper containers publish no ports.
- Each wrapped server has its **own credential** — one htpasswd file per server.
- nginx strips the `Authorization` header before proxying; wrapped servers never see gateway credentials.
- Responses may be SSE-formatted (`data: {...}` lines) — that's normal for Streamable HTTP.

## Prerequisites

- Docker with Compose plugin
- A running [Mealie](https://github.com/mealie-recipes/mealie) instance (or another MCP server you want to wrap)
- Mealie API token (Settings → API Tokens in Mealie)

## Quick start

1. **Configure environment**

   ```bash
   cp .env.example .env
   # Edit .env and set MEALIE_BASE_URL and MEALIE_API_KEY
   ```

2. **Create a gateway credential**

   ```bash
   bash add-auth.sh mealie
   ```

   Save the printed username and password — they are shown only once.

3. **Start the stack**

   ```bash
   docker compose up -d --build
   ```

4. **Smoke test**

   ```bash
   curl -u <user>:<password> -X POST http://localhost:48080/mealie \
     -H "Content-Type: application/json" \
     -H "Accept: application/json, text/event-stream" \
     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
   ```

   Expected: no credentials → `401`; unknown path → `404`; valid credentials → MCP `initialize` result.

## Connecting an MCP client

Point your MCP client at:

```
URL:      http://<host>:48080/mealie
Auth:     HTTP Basic (username + password from add-auth.sh)
```

If the client supports custom headers, send:

```
Authorization: Basic <base64(user:password)>
Accept: application/json, text/event-stream
```

## Configuration

### Environment variables (`.env`)

| Variable | Required | Description |
|---|---|---|
| `MEALIE_BASE_URL` | Yes | Base URL of your Mealie instance (e.g. `https://mealie.example.com`) |
| `MEALIE_API_KEY` | Yes | Mealie API token |
| `MEALIE_MCP_SOURCE` | No | Pin the Mealie MCP server to a specific commit: `git+https://github.com/rldiao/mealie-mcp-server@<sha>` |

### Restricting to localhost

Edit `docker-compose.yml` and change the nginx port mapping:

```yaml
ports:
  - "127.0.0.1:48080:48080"
```

## Adding a new MCP server

1. **Compose** — add a `<name>-mcp` service to `docker-compose.yml` reusing `image: mcp-supergateway:local`:

   ```yaml
   <name>-mcp:
     image: mcp-supergateway:local
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

2. **nginx** — copy `mealie.conf` to `nginx/locations/<name>.conf` (or the `nginx/locations/` dir if it exists), and update:
   - `location = /<name>`
   - `auth_basic_user_file /etc/nginx/auth/<name>.htpasswd`
   - `set $upstream "<name>-mcp:8000"`

3. **Auth** — create the credential:

   ```bash
   bash add-auth.sh <name>
   ```

4. **Env** — add any new variables to `.env.example` (placeholders only).

5. **Restart and verify**:

   ```bash
   docker compose up -d
   docker compose restart nginx
   # Run the smoke test against /<name>
   ```

## Common commands

```bash
docker compose up -d --build        # start / rebuild
docker compose logs -f mealie-mcp   # wrapper logs (first place to look when something fails)
docker compose logs -f nginx
docker compose exec nginx nginx -t  # validate nginx config
docker compose restart nginx        # pick up new/changed location files
bash add-auth.sh <name> [user]      # create or rotate a credential (prints it once)
```

## Security notes

- **Basic auth over plain HTTP** sends credentials in clear text. Keep this on localhost or a trusted VPN. For remote access, add TLS (nginx certificate, or put Caddy / Tailscale Serve in front).
- **Never commit** `.env` or `auth/` — both are gitignored.
- **One credential per server** — don't share htpasswd files across servers.
- Wrapper containers run with `no-new-privileges` and publish no ports.
- nginx strips the `Authorization` header before proxying to the wrapped server.

## Troubleshooting

| Symptom | Check |
|---|---|
| `401 Unauthorized` | Wrong credential, or `auth/<name>.htpasswd` missing. Re-run `add-auth.sh`. |
| `404 Not Found` | Wrong path, or `nginx/locations/<name>.conf` not mounted. Restart nginx. |
| `502 Bad Gateway` | Wrapper container is down or crashing. Check `docker compose logs -f <name>-mcp`. |
| Wrapper exits at start | Check `supergateway --help` flags; verify the stdio command runs. |
| No data from Mealie | Verify `MEALIE_BASE_URL` and `MEALIE_API_KEY` in `.env`; check wrapper logs. |
| nginx won't start | Run `docker compose exec nginx nginx -t` to validate config. |

## Project layout

```
docker-compose.yml           # one supergateway service per wrapped server, plus nginx
.env.example                 # template for .env (secrets); .env itself is never committed
add-auth.sh                  # creates/rotates auth/<name>.htpasswd and prints the credential once
Dockerfile                   # shared image: node + git + uv/uvx + supergateway
nginx.conf                   # main nginx config (at repo root or nginx/)
mealie.conf                  # nginx location block for the Mealie server (or nginx/locations/)
auth/                        # generated htpasswd files (gitignored, mounted read-only into nginx)
AGENTS.md                    # guidance for AI coding agents working in this repo
```

## License

Private use. See individual upstream projects for their licenses:
- [supergateway](https://github.com/supercorp-ai/supergateway)
- [mealie-mcp-server](https://github.com/rldiao/mealie-mcp-server)
- [Mealie](https://github.com/mealie-recipes/mealie)
