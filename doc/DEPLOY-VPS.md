# Deploy Paperclip on a VPS (always-on, public HTTPS)

This guide takes you from nothing to a Paperclip instance that is always
running, reachable at your own domain over HTTPS, and survives crashes and
server reboots.

It uses the bundled deploy stack in [`docker/deploy/`](../docker/deploy):

- **Caddy** — handles HTTPS and gets a free auto-renewing TLS certificate
- **Paperclip** — the app, in `authenticated/public` mode (login required)
- **PostgreSQL** — the database, on a persistent volume

Everything runs in Docker and restarts automatically.

## Easiest path (one script)

If you just want it up fast, steps 3–7 below are automated by `setup.sh`. After
you have a host (step 1) and DNS pointed at it (step 2):

```sh
git clone https://github.com/HenkDz/paperclip.git
cd paperclip/docker/deploy
./setup.sh paperclip.example.com you@example.com
```

The script installs Docker if needed, generates your secrets automatically,
opens the firewall, and starts the stack. Run it with no arguments to be
prompted instead. Re-running it is safe — it keeps your existing secrets. When
it finishes, do step 8 (create your admin account).

The manual steps below explain exactly what the script does, in case you want to
do it by hand or on a non-Ubuntu host.

## 1. Pick a host

**Recommended: [Hetzner Cloud](https://www.hetzner.com/cloud) — a `CX22`
instance** (2 vCPU, 4 GB RAM, ~€4/month).

Why this size and host:

- Paperclip + PostgreSQL + Caddy together want roughly 1.5–2 GB RAM under real
  use. 4 GB leaves headroom; a 1 GB box will struggle and may OOM during the
  Docker build.
- Hetzner is the cheapest reliable option at this size. The setup below is
  provider-agnostic, so **DigitalOcean** (Basic 4 GB droplet), **Linode**, **AWS
  Lightsail**, or any Ubuntu VPS work the same way — only the "create a server"
  step differs.

Create an **Ubuntu 24.04** server. Add your SSH key during creation so you can
log in without a password.

> Note on building on the server: the Docker build compiles the UI and server,
> which is memory-hungry. 4 GB is comfortable. If you must use a 1–2 GB box,
> either add swap or build the image elsewhere and push it to a registry.

## 2. Point your domain at the server

In your DNS provider, create an **A record**:

```
paperclip.example.com  ->  <your server's public IP>
```

Wait for it to resolve before continuing (TLS issuance needs working DNS):

```sh
dig +short paperclip.example.com
```

## 3. Install Docker on the server

SSH in (`ssh root@<server-ip>`), then:

```sh
curl -fsSL https://get.docker.com | sh
```

This installs Docker Engine and the Compose plugin.

## 4. Get the code

```sh
git clone https://github.com/HenkDz/paperclip.git
cd paperclip/docker/deploy
```

(Use your own fork URL if different.)

## 5. Configure secrets

```sh
cp .env.example .env
```

Edit `.env` and set:

- `PAPERCLIP_DOMAIN` — your domain, e.g. `paperclip.example.com`
- `ACME_EMAIL` — your email (for the TLS certificate)
- `BETTER_AUTH_SECRET` — run `openssl rand -hex 32` and paste the output
- `POSTGRES_PASSWORD` — run `openssl rand -hex 24` and paste the output

Optionally add `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` (you can also do this
later in the UI under company Secrets).

## 6. Open the firewall

Allow HTTP and HTTPS (HTTP is needed for the certificate challenge):

```sh
ufw allow 80
ufw allow 443
ufw allow OpenSSH
ufw enable
```

If your provider has its own firewall (Hetzner Cloud Firewall, AWS security
group, etc.), open ports **80** and **443** there too.

## 7. Start it

```sh
docker compose -f docker-compose.prod.yml up -d --build
```

The first build takes a while (it compiles the UI and server). Watch progress:

```sh
docker compose -f docker-compose.prod.yml logs -f
```

When it's ready you'll see Paperclip log `Server listening on 0.0.0.0:3100`
and Caddy will have fetched a certificate. Open:

```
https://paperclip.example.com
```

## 8. Claim the first admin account

Public deployments require login and do **not** allow browser-based first-admin
claim (a security choice). Mint a one-time admin invite from the server:

```sh
docker compose -f docker-compose.prod.yml exec paperclip \
  node --import ./server/node_modules/tsx/dist/loader.mjs \
  cli/src/index.ts auth bootstrap-ceo
```

This prints a one-time invite URL. Open it in your browser, create your account,
and you're the instance admin. From there, create your first company and agents.

## 9. Day-2 operations

```sh
# View logs
docker compose -f docker-compose.prod.yml logs -f

# Restart everything
docker compose -f docker-compose.prod.yml restart

# Stop / start
docker compose -f docker-compose.prod.yml down
docker compose -f docker-compose.prod.yml up -d

# Update to the latest code
git pull
docker compose -f docker-compose.prod.yml up -d --build
```

### Backups

Two things hold your state and should be backed up:

- the `pgdata` Docker volume (the database)
- the `paperclip-data` Docker volume (uploaded files + the local secrets key)

Paperclip also runs automatic logical DB backups inside the `paperclip-data`
volume on a timer (see `doc/DEVELOPING.md` → "Automatic DB Backups"). For real
disaster recovery, copy both volumes off the server periodically, for example:

```sh
docker run --rm -v paperclip_pgdata:/v -v "$PWD":/out alpine \
  tar czf /out/pgdata-backup.tgz -C /v .
docker run --rm -v paperclip_paperclip-data:/v -v "$PWD":/out alpine \
  tar czf /out/paperclip-data-backup.tgz -C /v .
```

(Volume names are prefixed with the compose project name, which defaults to the
directory name `deploy`. Run `docker volume ls` to confirm the exact names.)

## Troubleshooting

- **No certificate / site not loading:** DNS must point at the server and ports
  80 + 443 must be open before Caddy can issue a cert. Check `docker compose
  -f docker-compose.prod.yml logs caddy`.
- **`BETTER_AUTH_SECRET must be set` (or similar) on `up`:** a required value in
  `.env` is empty. Fill it in and re-run.
- **Build runs out of memory:** use a 4 GB instance, or add swap:
  `fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`.
- **Login/redirect issues:** make sure `PAPERCLIP_DOMAIN` in `.env` exactly
  matches the domain you open in the browser (it drives `PAPERCLIP_PUBLIC_URL`).

## Related docs

- `doc/DEPLOYMENT-MODES.md` — what `authenticated/public` means and the security policy
- `doc/DOCKER.md` — other Docker run options (quickstart, full stack, quadlet)
- `doc/DEVELOPING.md` — CLI commands, backups, secrets
