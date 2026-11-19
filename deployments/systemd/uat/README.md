# Deploy gtinx-plane lên UAT (Ubuntu + systemd)

Bộ file này deploy **toàn bộ** gtinx-plane Community trên một máy Ubuntu 22.04/24.04 bằng
`systemd`, không cần Docker. Kết quả gồm 9 unit + Caddy reverse proxy + TLS.

| Thành phần | Cổng (localhost) |
|---|---|
| API / worker / beat / migrate (Django) | `8000` |
| Live realtime (Hocuspocus) | `3100` |
| Web SPA (Caddy static) | `3200` |
| Admin `/god-mode` (Caddy static) | `3201` |
| Space SSR | `3202` |
| Proxy (Caddy) | `80/443` |
| MinIO (tuỳ chọn) | `9000` / console `9090` |

---

## 1. Chạy nhanh

```bash
# Trên server UAT (đã cài git, có sudo)
sudo mkdir -p /opt/gtinx-plane
sudo chown "$USER":"$USER" /opt/gtinx-plane
git clone <repo-url> /opt/gtinx-plane
cd /opt/gtinx-plane

# (tuỳ chọn) cấu hình trước khi chạy
cp deployments/systemd/uat/deploy-uat.conf.example deployments/systemd/uat/deploy-uat.conf
sudo nano deployments/systemd/uat/deploy-uat.conf

sudo bash deployments/systemd/uat/deploy-uat.sh
```

Script tự động:

1. cài PostgreSQL (PGDG 16 nếu là 22.04), Redis, RabbitMQ, Caddy 2.11+, Node 22, build tools
   (`libpq-dev` + `build-essential` vì `psycopg-c` build từ source)
2. tạo user hệ thống `gtinx`, thư mục `/etc/gtinx-plane`, `/var/lib/gtinx-plane`
3. sinh & lưu secret tại `/etc/gtinx-plane/uat-secrets.env` (chạy lại **không** đổi secret)
4. đồng bộ code vào `GTINX_DIR` và `chown` cho `gtinx`
5. ghi `/etc/gtinx-plane/{api,live,proxy}.env` (chỉ khi chưa có)
6. cài object storage local (mặc định **Silo** — fork MinIO còn được maintain) + `minio.service`
7. tạo role/database PostgreSQL, user/vhost RabbitMQ
8. `uv sync` (đúng version uv trong `pyproject.toml`, Python 3.12)
9. `pnpm install` + build `web/admin/space/live` với `VITE_*` same-origin
10. cài systemd units + Caddyfile, mở route `/uploads` khi dùng MinIO
11. enable + start toàn bộ service
12. health check `api / web / admin / space`

Kết thúc, mở `http://<ip>/god-mode/` (hoặc `https://<domain>/god-mode/`) để tạo instance + admin đầu tiên.

---

## 2. Cấu hình (`deploy-uat.conf`)

`cp deploy-uat.conf.example deploy-uat.conf` rồi sửa:

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `SITE_ADDRESS` | `:80` | `:80` = HTTP theo IP; `uat.example.com` = Caddy tự xin Let's Encrypt |
| `DISABLE_CONFLICTING_SERVICES` | `0` | `1` = tự tắt `nginx`/`apache2`/`httpd`/`lighttpd`/`caddy` mặc định đang chiếm cổng 80 |
| `APP_URL` | tự suy ra | URL public, dùng cho `WEB_URL`/CORS |
| `GTINX_DIR` | `/opt/gtinx-plane` | nơi đặt code |
| `GTINX_USER` | `gtinx` | user chạy service |
| `WITH_MINIO` | `1` | `0` = dùng S3 ngoài (`S3_ENDPOINT`, `AWS_ACCESS_KEY_ID`, ...) |
| `MINIO_FLAVOR` | `silo` | `silo` (fork MinIO, còn maintain) hoặc `minio` (binary cuối 09/2025, EOL) |
| `S3_BUCKET` | `uploads` | bucket upload file |
| `REDIS_PASSWORD` | *(rỗng)* | mật khẩu Redis gốc (không encode); script tự tạo `REDIS_URL` đúng chuẩn |
| `REDIS_HOST` / `REDIS_PORT` | `127.0.0.1` / `6379` | Redis nội bộ hoặc từ xa |
| `GUNICORN_WORKERS` | `min(nproc*2+1, 8)` | số worker API |
| `SKIP_PACKAGES` | `0` | `1` = bỏ qua apt (khi chạy lại) |
| `SKIP_BUILD` | `0` | `1` = không build lại FE |

**Dùng S3 ngoài** (AWS/R2/MinIO khác):

```bash
WITH_MINIO=0
S3_ENDPOINT="https://s3.ap-southeast-1.amazonaws.com"
S3_REGION="ap-southeast-1"
S3_BUCKET="gtinx-uat"
AWS_ACCESS_KEY_ID="..."
AWS_SECRET_ACCESS_KEY="..."
```

**Bật HTTPS**: đổi `SITE_ADDRESS="uat.example.com"`, mở port 80/443, DNS A record trỏ về server,
rồi chạy lại script (hoặc `sudo systemctl restart gtinx-plane-proxy`).

Lưu ý: `api.env`/`live.env`/`proxy.env` **không bị ghi đè** khi đã tồn tại. Muốn đổi giá trị
phải sửa trực tiếp trong `/etc/gtinx-plane/*.env` rồi restart service.

---

## 3. Kiểm tra

```bash
systemctl status gtinx-plane-api gtinx-plane-worker gtinx-plane-beat \
  gtinx-plane-live gtinx-plane-space gtinx-plane-web gtinx-plane-admin gtinx-plane-proxy

curl -fsS http://127.0.0.1:8000/api/instances/ >/dev/null && echo "api OK"
curl -fsS http://127.0.0.1:3200/ >/dev/null           && echo "web OK"
curl -fsS http://127.0.0.1:3201/god-mode/ >/dev/null  && echo "admin OK"
curl -fsS http://127.0.0.1:3202/spaces/ >/dev/null    && echo "space OK"
```

Test chức năng: tạo workspace → tạo issue → upload file (kiểm tra S3/MinIO) → mở 2 tab để test
realtime `/live` → tạo project public để test `/spaces`.

MinIO console chỉ listen `127.0.0.1:9090`, mở bằng SSH tunnel:

```bash
ssh -L 9090:127.0.0.1:9090 user@uat-server
# rồi mở http://127.0.0.1:9090
```

---

## 4. Vận hành

```bash
# Log
journalctl -u gtinx-plane-api -f
journalctl -u gtinx-plane-worker -f
journalctl -u gtinx-plane-proxy -n 200 --no-pager

# Restart an toàn
sudo systemctl restart gtinx-plane-migrate
sudo systemctl restart gtinx-plane-api gtinx-plane-worker gtinx-plane-beat \
  gtinx-plane-live gtinx-plane-space gtinx-plane-web gtinx-plane-admin gtinx-plane-proxy
```

### Nâng cấp code

```bash
cd /opt/gtinx-plane
sudo -u gtinx git pull
sudo SKIP_PACKAGES=1 bash deployments/systemd/uat/deploy-uat.sh
```

`SKIP_PACKAGES=1` bỏ qua apt; script vẫn chạy `uv sync`, build lại FE, cài lại unit và restart.
Dừng service trước nếu muốn zero-downtime thấp hơn:

```bash
sudo systemctl stop gtinx-plane-proxy gtinx-plane-web gtinx-plane-admin gtinx-plane-space \
  gtinx-plane-live gtinx-plane-api gtinx-plane-worker gtinx-plane-beat
```

### Backup

```bash
# Database
sudo -u postgres pg_dump -Fc gtinx_plane > /var/backups/gtinx-plane-$(date +%F).dump

# File upload (MinIO local)
sudo tar czf /var/backups/gtinx-minio-$(date +%F).tgz -C /var/lib/gtinx-plane minio

# Cấu hình + secret
sudo tar czf /var/backups/gtinx-config-$(date +%F).tgz /etc/gtinx-plane
```

> `uat-secrets.env` chứa `SECRET_KEY` — mất file này thì dữ liệu mã hoá trong DB không đọc được.
> Backup riêng và giữ cẩn thận.

---

## 5. Xử lý sự cố

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| `api` exit, log `GUNICORN_WORKERS` | thiếu biến trong `/etc/gtinx-plane/api.env` |
| API 500 `no such table` | `gtinx-plane-migrate` chưa xong: `systemctl status gtinx-plane-migrate` |
| `uv sync` lỗi `pg_config` | thiếu `libpq-dev`/`build-essential` — chạy lại không `SKIP_PACKAGES` |
| `uv` báo `Required uv version ==x.y.z does not match` | installer uv luôn cài bản latest, script pin lại sau khi cài; nếu chạy tay: `uv self update <version trong pyproject.toml>` (user `gtinx`, `PATH=$HOME/.local/bin:$PATH`) |
| `pnpm install` lỗi `husky` | script đã set `HUSKY=0`; nếu chạy tay thì export `HUSKY=0` |
| Web 404 toàn bộ | chưa build web hoặc `root` trong `web.Caddyfile` sai |
| `/god-mode/` trắng trang | build admin thiếu `VITE_ADMIN_BASE_PATH=/god-mode` |
| 502 ở `/api/*` | API không listen `8000`: `ss -lntp \| grep 8000` |
| Upload lỗi | `AWS_*`/`USE_MINIO` sai, hoặc route `/uploads` trong `proxy.Caddyfile` bị comment |
| WebSocket `/live` lỗi | `LIVE_SERVER_SECRET_KEY` lệch giữa `api.env` và `live.env` |
| Caddy lỗi TLS | DNS chưa trỏ về server, port 80/443 bị chặn, `SITE_ADDRESS` sai |
| `status=203/EXEC` | sai đường dẫn `ExecStart` — kiểm tra `which node`, `which caddy` |
| `curl: (22) ... error: 410` khi tải MinIO | `dl.min.io` đã ngừng phát hành binary (9/2026): dùng `MINIO_FLAVOR=silo` (mặc định) hoặc trỏ `MINIO_BINARY_URL` sang GitHub release |
| `minio.service` fail, log `Access denied` | thư mục `MINIO_DATA` sai quyền: `sudo chown -R gtinx:gtinx /var/lib/gtinx-plane/minio` |
| API log `NOAUTH Authentication required` | Redis có `requirepass` nhưng `REDIS_URL` thiếu mật khẩu — xem mục 8 bên dưới |
| API log `WRONGPASS` / `invalid password` | mật khẩu chưa URL-encode (`@` → `%40`, `#` → `%23`) hoặc `requirepass` khác với `REDIS_PASSWORD` |
| Mở `http://<IP>/` thấy **"Welcome to nginx!"** | một web server khác (nginx/apache2) đang giữ cổng 80 — xem mục 9 bên dưới |
| `gtinx-plane-proxy` log `address already in use` | cùng nguyên nhân trên: cổng 80/443 bị chiếm |

Xem log chi tiết:

```bash
journalctl -xeu gtinx-plane-api --no-pager | tail -80
journalctl -u gtinx-plane-migrate --no-pager | tail -80
```

---

## 6. Bảo mật

- `/etc/gtinx-plane/*.env` là `0640 root:gtinx`; `uat-secrets.env` là `0600 root:root`.
- Unit chạy bằng user `gtinx` với `NoNewPrivileges`, `ProtectSystem`, `PrivateTmp`.
- Chỉ proxy bind `80/443` (qua `CAP_NET_BIND_SERVICE`).
- Các cổng `8000/3100/3200-3202` chỉ nên truy cập nội bộ. Nếu không dùng ufw, chặn bằng
  security group/firewall của nhà cung cấp.
- UAT vẫn nên đặt `DEBUG=0` (script đã set) và secret riêng, không dùng chung với production.

---

## 7. Cấu trúc file

```
deployments/systemd/
├── uat/
│   ├── deploy-uat.sh          # script deploy (idempotent)
│   ├── deploy-uat.conf.example
│   └── README.md              # file này
├── units/                     # 9 systemd unit
├── caddy/                     # web/admin/proxy Caddyfile
├── env/                       # mẫu env (script ghi đè bằng bản đã điền)
├── install.sh                 # cài unit + Caddyfile + env
└── README.md                  # hướng dẫn gốc (thủ công)
```

---

## 8. Redis có mật khẩu

Kiểm tra Redis:

```bash
redis-cli -h 127.0.0.1 -p 6379 -a 'Cts@12345' --no-auth-warning ping   # phải trả PONG
```

Cấu hình qua script (chỉ có tác dụng khi `api.env`/`live.env` **chưa tồn tại**):

```bash
sudo SKIP_PACKAGES=1 REDIS_PASSWORD='Cts@12345' bash deployments/systemd/uat/deploy-uat.sh
```

Nếu 2 file đã có (trường hợp deploy dang dở), sửa tay rồi restart:

```bash
sudo sed -i 's|^REDIS_URL=.*|REDIS_URL="redis://:Cts%4012345@127.0.0.1:6379/"|' \
  /etc/gtinx-plane/api.env /etc/gtinx-plane/live.env

sudo systemctl restart gtinx-plane-api gtinx-plane-worker gtinx-plane-beat gtinx-plane-live
```

Quy tắc: `redis://:<password-đã-URL-encode>@host:6379/`

| Ký tự | Encode |
|---|---|
| `@` | `%40` |
| `#` | `%23` |
| `/` | `%2F` |
| `:` | `%3A` |
| `?` | `%3F` |
| `%` | `%25` |

Encode tự động:

```bash
python3 -c "import urllib.parse; print(urllib.parse.quote('Cts@12345', safe=''))"
# Cts%4012345
```

Sau khi restart, log API không còn `NOAUTH`/`WRONGPASS` là đúng:

```bash
journalctl -u gtinx-plane-api -n 50 --no-pager | grep -i -E 'redis|auth|error'
```

> Nếu mật khẩu chỉ đặt tạm bằng `redis-cli CONFIG SET requirepass ...` (không ghi vào
> `/etc/redis/redis.conf`), nó sẽ mất sau khi restart Redis. Đặt `requirepass` trong file config
> để giữ cố định.

---

## 9. Cổng 80 bị chiếm (thấy "Welcome to nginx!")

Nếu mở `http://<IP>/` thấy trang mặc định của nginx/apache trong khi `gtinx-plane-*` vẫn `active`,
thì web server khác đang giữ cổng 80 — `gtinx-plane-proxy` (Caddy) không bind được.

```bash
ss -lntp | grep ':80\b'
systemctl is-active nginx apache2 httpd lighttpd caddy gtinx-plane-proxy
journalctl -u gtinx-plane-proxy -n 50 --no-pager | grep -iE 'bind|address|error'
```

Tắt web server không dùng (ví dụ nginx cài mặc định):

```bash
sudo systemctl disable --now nginx
sudo systemctl restart gtinx-plane-proxy
curl -I http://127.0.0.1/
```

Hoặc để script tự tắt các web server đang chiếm cổng 80:

```bash
sudo DISABLE_CONFLICTING_SERVICES=1 bash deployments/systemd/uat/deploy-uat.sh
```

> Chỉ làm vậy khi máy chủ **không** dùng nginx/apache cho site khác. Nếu đang dùng, giữ nguyên
> và thêm reverse proxy trong nginx trỏ về `127.0.0.1:3200` (web), `127.0.0.1:8000/api/*`,
> `127.0.0.1:3201/god-mode/*`, `127.0.0.1:3202/spaces/*`, `127.0.0.1:3100/live/*`.
