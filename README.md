# Nginx Reverse‑Proxy Stack (MediaWiki + Certbot + imgproxy + GoAccess)

A production‑ready Docker Compose stack that fronts your web apps (e.g., MediaWiki) with **Nginx**, handles **TLS automation with Certbot**, serves **next‑gen images via imgproxy** (AVIF/WebP negotiation with caching & failover), and provides **real‑time traffic analytics with GoAccess** (WebSocket proxied, behind Basic Auth). It also includes sane **log rotation** and **proxy cache** settings.

> The stack is designed to run on a single host with Docker, expose multiple virtual hosts, and keep configuration tidy via reusable “includes”.

---

## Features

- **TLS automation (Let’s Encrypt / Certbot)**
  - Webroot HTTP‑01 challenge via a dedicated `/.well-known/acme-challenge/` location.
  - One‑shot issuance script from a `domains.list` file (one certificate per line).
  - Safe renewals (no need to stop Nginx) and dry‑run support.
  - Ready for OCSP stapling (subject to CA certificate OCSP URL availability).

- **Hardened reverse proxy**
  - HTTP/2, SNI, and strict security headers (HSTS, X‑Content‑Type‑Options, etc.).
  - Clean separation via `includes/` for security headers, caching, certbot, and upstream maps.
  - ENV‑driven backend mapping so TEST/PROD switches are minimal.

- **Smart image delivery with imgproxy**
  - Content negotiation: AVIF → WebP → PNG/JPEG fallback based on `Accept`.
  - Long‑lived, immutable caching with variant‑aware cache keys.
  - **Failover:** if imgproxy is unavailable, Nginx falls back to origin thumbnails.
  - SVG passthrough (no accidental raster conversion).

- **Real‑time analytics with GoAccess**
  - Uses a single **virtual‑host aware** access log (per‑vhost analytics).
  - Real‑time HTML dashboard via WebSockets proxied at `/ws`.
  - **Basic Auth** on the stats vhost; WS endpoint whitelisted with an **Origin** gate.
  - Custom **bot list** and referrer filters to keep “Unique Visitors” sane.
  - Persistent DB so historical stats survive container restarts.

- **Logging & rotation**
  - Unified `access_all.log` + error logs per vhost (optional).
  - **logrotate sidecar** with `copytruncate` for zero‑downtime rotation.
  - Size/time‑based retention with compression.

---

## Prerequisites

- Docker & Docker Compose
- DNS A/AAAA records pointing to your host
- Ports **80** and **443** reachable from the Internet

---

## Quickstart

1. **Clone & enter the repo**

   ```bash
   cd /opt
   git clone <this-repo-url> nginxproxy
   cd nginxproxy
   ```

2. **Copy example files (adjust parameters as needed)**

   ```bash
   # Environment
   cp .env.example .env

   # Nginx vhosts & includes
   cp -r data/nginx/conf.d/global.conf.example data/nginx/conf.d/global.conf
   cp -r data/nginx/conf.d/stats.example.com.conf.example data/nginx/conf.d/<stats.example.com.conf>
   cp -r data/nginx/conf.d/www.example.com.conf.example data/nginx/conf.d/<www.example.com.conf>
   cp -r data/nginx/conf.d/includes/certbot.conf.example data/nginx/conf.d/includes/certbot.conf
   cp -r data/nginx/conf.d/includes/security-headers.conf.example data/nginx/conf.d/includes/security-headers.conf
   cp -r data/nginx/conf.d/includes/site-defaults.conf.example data/nginx/conf.d/includes/site-defaults.conf
   cp -r data/nginx/conf.d/includes/ssl.conf.example data/nginx/conf.d/includes/ssl.conf

   # Certbot webroot & config (persisted)
   mkdir -p data/letsencrypt/{conf,webroot,lib,logs}

   # GoAccess config & dashboards
   cp data/goaccess/goaccess.conf.example data/goaccess/conf/goaccess.conf
   cp data/goaccess/browsers.list.example data/goaccess/conf/browsers.list

   # Logrotate sidecar
   cp data/logrotate/nginx-acccess.example data/logrotate/conf/nginx-access
   ```

3. **Define certificates to issue**

   - Edit `domains.list` — *one certificate per line*, first domain is the cert name:

     ```text
     example.com www.example.com
     stats.example.com
     ```

4. **Bring the stack up**

   ```bash
   docker compose up -d
   ```

5. **Issue certificates (staging/dry‑run first)**

   ```bash
   ./scripts/issue-from-list.sh domains.list   # uses the running certbot container
   ```

   - The script supports `--staging` / `--dry-run` toggles internally; switch off for production issuance.

6. **Visit your sites**

   - Your app vhosts (e.g., `https://www.example.com`)
   - Real‑time stats at `https://stats.example.com` (behind Basic Auth)

---

## Folder layout (typical)

```txt
.
├─ docker-compose.yml
├─ .env
├─ geoipupdate.env
├─ data/
│  ├─ nginx/
│  │  └─ conf.d/
│  │     ├─ global.conf
│  │     ├─ <vhosts>.conf
│  │     └─ includes/
│  │        ├─ security.conf
│  │        ├─ certbot.conf
│  │        ├─ cache.conf
│  │        └─ upstreams.map.conf
│  ├─ letsencrypt/
│  │  ├─ conf/            # certs (mounted read-only into nginx)
│  │  └─ webroot/         # HTTP-01 challenge files
│  └─ goaccess/
│     ├─ goaccess.conf
│     └─ browsers.list
├─ issue-from-list.sh
├─ domains.list
├─ nginx_imgproxy_testing.sh
└─ goaccess-referrer-ignore.sh

```

---

## Configuration highlights

### 1) Certbot challenge (works for issuance **and** renewals)

```nginx
# includes/certbot.conf
location ^~ /.well-known/acme-challenge/ {
    root /srv/certbot/www;
    default_type "text/plain";
    add_header Cache-Control "no-store";
    try_files $uri =404;
    auth_basic off;
    allow all;
}
```

### 2) Image negotiation & caching (imgproxy in front, fallback to origin)

```nginx
# Map Accept -> target format
map $http_accept $imgfmt {
    "~*image/avif"  "avif";
    "~*image/webp"  "webp";
    default         "png";
}

# Cache key must vary by format!
proxy_cache_path /var/cache/nginx/img levels=1:2 keys_zone=img_cache:50m inactive=30d max_size=5g;

location ~* ^/images/(?:thumb/)?(.+\.(?:jpe?g|png|gif|webp|avif))$ {
    set $src "http://mediawiki$uri$is_args$args";   # or env-driven upstream

    # variant-aware cache
    proxy_cache        img_cache;
    proxy_cache_key    "$scheme$proxy_host$uri|$imgfmt";
    add_header X-Cache $upstream_cache_status always;

    # pass to imgproxy
    proxy_pass http://imgproxy:8989/insecure/plain/$src@$imgfmt;

    # serve stale on trouble & fallback to origin
    proxy_cache_use_stale error timeout invalid_header http_500 http_502 http_503 http_504 updating;
    proxy_next_upstream  error timeout http_500 http_502 http_503 http_504 non_idempotent;
    error_page 502 503 504 = @origin_fallback;

    proxy_hide_header Vary;
    add_header Vary Accept always;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";
}

location @origin_fallback {
    proxy_pass http://mediawiki;
    expires 30d;
    add_header Cache-Control "public, max-age=2592000, immutable";
}
```

### 3) Stats vhost (GoAccess) with Basic Auth & WebSocket proxy

```nginx
# Protect everything by default
auth_basic "Restricted";
auth_basic_user_file /etc/nginx/conf.d/.htpasswd.pwd;

# Real-time WS under /ws (no Basic Auth, but origin-gated)
location /ws {
    auth_basic off;
    if ($http_origin !~* "^https://stats\.example\.com$") { return 403; }

    proxy_pass http://goaccess:7890;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header Host $host;
}
```

### 4) Access log with virtual host + UA

```nginx
# http {} block
log_format vcombined '$host $remote_addr - $remote_user '
                     '[$time_local] "$request" $status $body_bytes_sent '
                     '"$http_referer" "$http_user_agent"';
access_log /var/log/nginx/access_all.log vcombined;
```

---

## Environment Configuration (`.env`) — Reference

This chapter documents every variable in `nginxproxy/.env.example` and when/how to change it. Copy the file to `.env` and adjust the values for your setup.

---

### Project basics

| Variable | Example | Purpose | Notes |
|---|---|---|---|
| `PROJECT_NAME` | `nginxproxy` | Docker Compose project name | Used as container/network prefix. Keep it short and stable. |

---

### GoAccess (real-time analytics)

| Variable | Example | Purpose | Notes |
|---|---|---|---|
| `GOACCESS_PORT` | `127.0.0.1:7890` | Bind address for GoAccess WebSocket server | Keep it on `127.0.0.1` and proxy it via NGINX; don’t expose publicly. |
| `GA_SSL_KEY` | `/etc/letsencrypt/live/stats.example.com/privkey.pem` | TLS key used by GoAccess itself | Use certs that match your stats domain. |
| `GA_SSL_CERT` | `/etc/letsencrypt/live/stats.example.com/fullchain.pem` | TLS full chain for GoAccess | Same certificate pair as your stats vhost. |
| `GA_WS_URL` | `wss://stats.example.com/ws` | External WS URL GoAccess advertises to the HTML page | Must be `wss://…` when served behind HTTPS. |
| `GA_ORIGIN` | `https://stats.example.com` | Allowed browser origin for WebSocket connections | Must match the public URL serving the dashboard. |

**Tips**

- If you terminate TLS at NGINX only, you can still run GoAccess with `GOACCESS_PORT=127.0.0.1:7890` and let the vhost proxy `/ws` to it.  
- Ensure your NGINX vhost forwards `Upgrade` and `Connection` headers for WebSocket.

---

### imgproxy (on-the-fly image optimization)

| Variable | Example | Purpose | Notes |
|---|---|---|---|
| `IMGPROXY_BIND` | `127.0.0.1:8989` | Bind address for imgproxy | Keep it on loopback; vhost proxies requests. |
| `IMGPROXY_ALLOWED_SOURCES` | `http://mediawiki:8091,http://127.0.0.1:8091` | Comma-separated list of allowed source origins | Add all backends that serve your original images (MediaWiki, test env, etc.). |
| `IMGPROXY_ALLOW_LOOPBACK_SOURCE_ADDRESSES` | `true` | Allow `127.0.0.1`/`localhost` as image sources | Useful in container-to-container setups. |
| `IMGPROXY_ENFORCE_WEBP` | `false` | Force WebP output for all clients | Usually keep `false` and negotiate by `Accept`. |
| `IMGPROXY_PREFER_WEBP` | `false` | Prefer WebP when client supports it | You can negotiate in NGINX; leaving `false` is fine. |
| `IMGPROXY_QUALITY` | `75` | Default quality for non-WebP formats | 70–80 is a good balance. |
| `IMGPROXY_WEBP_QUALITY` | `75` | Quality for WebP output | Can often be a bit lower for similar visual quality. |
| `IMGPROXY_STRIP_METADATA` | `true` | Remove EXIF/ICC/etc. | Saves bytes and avoids leaking camera/location data. |
| `IMGPROXY_MAX_SRC_RESOLUTION` | `50` | Max source megapixels (width × height ÷ 1e6) | Protects against huge inputs; set `0` to disable. |
| `IMGPROXY_DOWNLOAD_TIMEOUT` | `5` | Max seconds to fetch source image | Tune if backends are slow. |
| `IMGPROXY_READ_REQUEST_TIMEOUT` | `5` | Max seconds to read request | Safety limit for slow clients. |

**Security recommendations**

- Keep imgproxy bound to `127.0.0.1` and only reachable via NGINX.

---

### Timezone

| Variable | Example | Purpose |
|---|---|---|
| `TZ` | `Europe/Berlin` | Container timezone for logs and time-based tasks. |

---

## goaccess

### `goaccess-referrer-ignore.sh`

## generate Basic Auth Password file (.htpasswd)

we will use the **apache http docker image** and generate the `.htpasswd` file with that container,
because nginx does not come with a `htpasswd` binary.

```bash
# first time, to create the .htpasswd file
docker run --rm -it \
  -v $(pwd)/data/nginx/conf.d/:/work \
  httpd:2-alpine \
  htpasswd -c /work/.htpasswd <username>

# without -c to append users
docker run --rm -it \
  -v $(pwd)/data/nginx/conf.d/:/work \
  httpd:2-alpine \
  htpasswd /work/.htpasswd <username>

# none interactive, add -c if you like to create a new file
docker run --rm \
  -v $(pwd)/data/nginx/conf.d/:/work \
  httpd:2-alpine \
  htpasswd -b /work/.htpasswd <username> <password>
```

## Issue new SSL certificate

if you like to issue a new certificate you need to setup DNS first. So the Domainname is pointing to the nginx servers IPv4 or IPv6 address. Then edit or create the `domains.list`:

- File with domain lists (one list per line, separate domains with spaces)
- domains.list is used as the default, or the first parameter.
- Example:

    ```txt
    example.com www.example.com
    example.org www.example.org blog.example.org
    ```

then start the issue script.

```bash
chmod +x issue-from-list
./issue-from.list.sh domains.list
```

## Renewall tests

here are some comands to check if the renewal process of certbot will work.

```bash
# all certs (dryrun only)
docker compose exec certbot certbot renew --dry-run

# Only dry test a specific certificate (dryrun only)
docker compose exec certbot certbot renew --cert-name lhlab.wiki --dry-run

# Force immediate testing (even if it is not yet 30 days before expiry) (dryrun only)
docker compose exec certbot certbot renew --cert-name lhlab.wiki --dry-run --force-renewal

```

## NGINX + IMGProxy Cache Test Suite `nginx_imgproxy_testing.sh`

A compact Bash script to verify end‑to‑end image delivery and HTML/CDN caching for the NGINX / MediaWiki stack (NGINX reverse proxy + IMGProxy + MediaWiki). It prints focused headers and clear **OK/WARN/FAIL** results for each step.

- Image cache warmup (**MISS → HIT**) with `X-Cache` validation
- Content negotiation via `Accept:` (**AVIF**, **WebP**, PNG fallback)
- Logged‑in/cache‑bypass checks (cookies, `?nocache=1`, `action=edit`, POST)
- Validator passthrough (**ETag**, **Last‑Modified**) and optional fallback detection
- Optional direct tests against **IMGProxy** (including **304 revalidation**)

### Configuration

The script is self‑contained. Edit the **CONFIGURATION** block at the top:

- `HOST`, `IMG` – target host and an existing image path
- `BASE_URL`, `PAGE_CACHEABLE`, `PAGE_START` – pages used for HTML/CDN checks
- `NEGATE_QS_FOR_NEG` – use image URL without query for negotiation tests (default: `1`)
- `EXPECT_FALLBACK` – set `1` only when you intentionally stop IMGProxy to verify fallback
- `IMGPROXY_LOCAL`, `MW_BACKEND_IMAGEURL` – enable optional direct IMGProxy checks

> Requirements: `bash`, `curl`

## Usage

```bash
chmod +x ./nginx_imgproxy_testing.sh
./nginx_imgproxy_testing.sh
```

The script prints the relevant response headers and summarizes results at the end. A non‑zero exit code indicates at least one **FAIL**.
