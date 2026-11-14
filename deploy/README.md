# Deploying 1-Apply to AWS EC2 (Docker + HTTPS)

One small EC2 instance runs three containers: **web** (Next.js), **caddy** (HTTPS) and **cron** (deadline sweep and host-submit). Supabase stays the database. Every push to `main` builds an arm64 image on GitHub, pushes it to GHCR and rolls it out over SSH.

```text
Browser ──HTTPS──► Caddy :443 ──► web :3000 ──► Supabase (DB, auth, storage)
                                   ▲
                    cron ──────────┘  every 5 / 15 min
```

**No domain needed.** The site is served at `https://<ip-with-dashes>.sslip.io`, e.g. `https://13-232-10-20.sslip.io`. sslip.io is a free DNS service that resolves that name to the IP inside it, so Caddy can get a real Let's Encrypt certificate. When you buy a domain later, see [Moving to a real domain](#moving-to-a-real-domain).

**Cost:** about $17–18/month (t4g.small + 20 GB gp3 + public IPv4).

---

## 1. Launch the instance (AWS console)

Region: **Asia Pacific (Mumbai) `ap-south-1`**, top-right of the console.

**EC2 → Instances → Launch instance:**

| Setting | Value |
|---|---|
| Name | `1apply-prod` |
| AMI | **Ubuntu Server 24.04 LTS**, architecture **64-bit (Arm)** |
| Instance type | **t4g.small** |
| Key pair | Create new → `1apply-prod` → RSA → `.pem`. Download it and keep it safe. |
| Network → Security group | Create one with the three rules below |
| Storage | **20 GiB gp3** |
| Advanced details → User data | Paste the whole of [`ec2-bootstrap.sh`](./ec2-bootstrap.sh) |

Security group inbound rules:

| Type | Port | Source | Why |
|---|---|---|---|
| HTTP | 80 | Anywhere (0.0.0.0/0) | Certificate issuance + redirect to HTTPS |
| HTTPS | 443 | Anywhere (0.0.0.0/0) | The app |
| SSH | 22 | Anywhere (0.0.0.0/0) | GitHub Actions deploys over SSH from changing IPs. Key-only login; passwords are disabled on Ubuntu AMIs. |

The user data installs Docker, adds 2 GB swap and creates `/opt/1apply`. It takes 2–3 minutes after the instance starts.

## 2. Give it a fixed IP

**EC2 → Elastic IPs → Allocate Elastic IP address → Allocate**, then **Actions → Associate** → pick `1apply-prod`.

Your app domain is that IP with dashes plus `.sslip.io`. For an IP of `13.232.10.20`:

```text
APP_DOMAIN = 13-232-10-20.sslip.io
APP URL    = https://13-232-10-20.sslip.io
```

## 3. Create the server's env file

```bash
ssh -i 1apply-prod.pem ubuntu@<ELASTIC_IP>
cloud-init status --wait          # wait for the bootstrap to finish
docker --version                  # sanity check
cd /opt/1apply
cp .env.example .env
nano .env
chmod 600 .env
```

Fill in `.env`. Type the values on the server; don't paste them into chats or tickets.

| Variable | Value |
|---|---|
| `APP_DOMAIN` | **add this line**: `13-232-10-20.sslip.io` (yours) |
| `NEXT_PUBLIC_APP_URL` | `https://13-232-10-20.sslip.io` |
| `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` | From Supabase → Project Settings → API |
| `SUPABASE_SERVICE_ROLE_KEY` | Same page (server-only) |
| `GROQ_API_KEY` and/or `OPENAI_API_KEY` | AI providers (`OPENAI_*` is the Gemini key) |
| `CRON_SECRET`, `TOKEN_ENCRYPTION_KEY` | Generate each with `openssl rand -hex 32` |
| `NEXT_PUBLIC_EXTENSION_ORIGIN` | `chrome-extension://<extension id>` if you use the extension |

`WEB_IMAGE` is added automatically by the first deploy.

## 4. Configure GitHub (repository owner)

On a personal-account repository only the **owner** can manage Actions secrets and variables.

**Settings → Secrets and variables → Actions:**

| Kind | Name | Value |
|---|---|---|
| Variable | `DEPLOY_HOST` | The Elastic IP, e.g. `13.232.10.20`. **Setting this turns the workflow on.** |
| Variable | `APP_URL` | `https://13-232-10-20.sslip.io` |
| Variable (optional) | `DEPLOY_USER` | Defaults to `ubuntu` |
| Secret | `DEPLOY_SSH_KEY` | Full contents of `1apply-prod.pem` |
| Secret (existing) | `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_EXTENSION_ORIGIN` | Already used by the old workflow. Reused as-is. |

## 5. Point Supabase (and Google) at the new URL

- **Supabase → Authentication → URL Configuration:** set **Site URL** to `https://13-232-10-20.sslip.io` and add `https://13-232-10-20.sslip.io/**` to **Redirect URLs**. Without this, sign-up and magic links send people to the old address.
- **Google OAuth** (only if Gmail/Calendar sync is used): add `https://13-232-10-20.sslip.io/api/integrations/callback?kind=gmail` and `…?kind=google_calendar` as authorized redirect URIs.

## 6. Deploy

**Actions → Deploy (Docker → EC2) → Run workflow** (or push to `main`). The first run takes about 8–10 minutes, later runs are faster thanks to the build cache. Then open:

```text
https://13-232-10-20.sslip.io/api/health   →  {"data":{"ok":true,...}}
```

The certificate is requested on the first HTTPS request, so the very first load can take a few seconds.

## 7. Rebuild the Chrome extension for the new URL

```bash
EXTENSION_APP_BASE_URL=https://13-232-10-20.sslip.io npm run build -w @1apply/extension
```

Load `apps/extension/dist` unpacked. The build adds the new origin to the manifest's host permissions and bridge script automatically.

## 8. Retire the old server

Once the new URL works end to end:

1. Delete `.github/workflows/deploy-ec2.yml`. It still deploys the old PM2 server on every push until you do.
2. Terminate the old instance and **release its Elastic IP**. AWS bills for unattached Elastic IPs.
3. Remove the old `EC2_HOST`, `EC2_USER` and `EC2_SSH_KEY` secrets.

---

## Day-to-day operations

All commands run on the server in `/opt/1apply`:

```bash
alias dc='docker compose -f docker-compose.prod.yml'
dc ps                     # status
dc logs -f web            # app logs (also: caddy, cron)
dc restart web            # restart after editing .env
```

**Change a secret:** edit `.env`, then `dc up -d`. `NEXT_PUBLIC_*` values are baked into the build, so change them in GitHub (`APP_URL` variable or the secrets) and redeploy.

**Roll back:** every build is tagged with its commit SHA.

```bash
sed -i 's|^WEB_IMAGE=.*|WEB_IMAGE=ghcr.io/<owner>/1apply-web:<older-sha>|' .env
docker login ghcr.io        # GitHub username + a token with read:packages
dc up -d
```

**Server-side Playwright submit** (off by default): add `INSTALL_PLAYWRIGHT_CHROMIUM=true` to the workflow's `build-args` (about 500 MB larger image) and set `ENABLE_SERVER_HOST_SUBMIT=true` in `.env`.

## Moving to a real domain

1. Point an `A` record for e.g. `app.example.com` at the Elastic IP.
2. In `.env`: `APP_DOMAIN=app.example.com` and `NEXT_PUBLIC_APP_URL=https://app.example.com`.
3. In GitHub: `APP_URL=https://app.example.com`, then redeploy.
4. Repeat step 5 (Supabase/Google URLs) and step 7 (extension).

## Troubleshooting

| Symptom | Check |
|---|---|
| Workflow didn't run | `DEPLOY_HOST` variable is set |
| SSH step fails | Security group allows 22; `DEPLOY_SSH_KEY` is the full `.pem` including the BEGIN/END lines |
| Browser shows a certificate error | `dc logs caddy`. Ports 80 and 443 must be open and `APP_DOMAIN` must match the Elastic IP |
| Sign-in link goes to the wrong site | Supabase Site URL / Redirect URLs (step 5) |
| `web did not become healthy` | `dc logs web`. Usually a missing or typo'd value in `.env` |
