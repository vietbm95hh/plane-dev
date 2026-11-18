# Self-hosting với systemd

Tài liệu này mô tả cách chạy nền tảng quản lý dự án trong repo này trên **một máy Linux** dùng
`systemd`, **không cần Docker**. Bộ file Docker trong repo vẫn được giữ nguyên và không bị ảnh
hưởng — hai cách chạy có thể tồn tại song song.

- Backend API / worker / scheduler: **Python 3.12 + Django + Celery**
- Frontend (web, admin, space) và realtime server: **TypeScript / Node.js 22**
- Reverse proxy + TLS: **Caddy**

---

## 1. Kiến trúc

```
Internet
   │
   ▼
Caddy :80 / :443                        (gtinx-plane-proxy.service)
   ├─ /                 → 127.0.0.1:3200  web    (SPA tĩnh)
   ├─ /god-mode/*       → 127.0.0.1:3201  admin  (SPA tĩnh)
   ├─ /spaces/*         → 127.0.0.1:3202  space  (SSR)
   ├─ /live/*           → 127.0.0.1:3100  live   (WebSocket)
   ├─ /api/* /auth/* /static/* → 127.0.0.1:8000  api (Django)
   └─ /uploads/*        → 127.0.0.1:9000  object storage (tuỳ chọn)
                                              │
        PostgreSQL ◄── api / worker / beat ────┤
        Redis      ◄── api / worker / live ────┤
        RabbitMQ   ◄── api / worker / beat ────┘
```

| Unit                     | Thành phần                       | Cổng nội bộ |
| ------------------------ | -------------------------------- | ----------- |
| `gtinx-plane-migrate.service`  | Django migrate (`oneshot`)       | –           |
| `gtinx-plane-api.service`      | Django API (gunicorn + uvicorn)  | `8000`      |
| `gtinx-plane-worker.service`   | Celery worker                    | –           |
| `gtinx-plane-beat.service`     | Celery beat                      | –           |
| `gtinx-plane-live.service`     | Realtime server (Hocuspocus)     | `3100`      |
| `gtinx-plane-space.service`    | Space – trang public (SSR)       | `3202`      |
| `gtinx-plane-web.service`      | Web frontend (Caddy static)      | `3200`      |
| `gtinx-plane-admin.service`    | Admin god-mode (Caddy static)    | `3201`      |
| `gtinx-plane-proxy.service`    | Reverse proxy + TLS (Caddy)      | `80/443`    |

Các service dùng chung network namespace của host, nên mỗi service phải listen một cổng riêng.
Toàn bộ unit, Caddyfile và mẫu env nằm trong [`deployments/systemd/`](./deployments/systemd/).

> API / worker / beat / migrate tái sử dụng nguyên các script trong `apps/api/bin/`, nên hành vi
> production giống hệt bản chạy container.

---

## 2. Yêu cầu hệ thống

| Thành phần  | Phiên bản tối thiểu | Ghi chú                          |
| ----------- | ------------------- | -------------------------------- |
| OS          | Ubuntu 22.04/24.04, Debian 12 | cần `systemd`           |
| Node.js     | 22.22               | + `corepack` / `pnpm`            |
| Python      | 3.12 (chưa hỗ trợ 3.13) | + [uv](https://docs.astral.sh/uv/) |
| PostgreSQL  | 15                  | `max_connections` ≥ 200          |
| Redis/Valkey| 7                   | cache + Celery result backend    |
| RabbitMQ    | 3.13                | Celery broker                    |
| Caddy       | 2.11                | proxy + phục vụ file tĩnh        |
| Object store| S3 hoặc MinIO       | lưu file upload                  |

Gợi ý tài nguyên cho một instance nhỏ (≤ 50 user): **4 vCPU / 8 GB RAM / 50 GB SSD**.

### Cài đặt gói phụ thuộc

```bash
sudo apt update
sudo apt install -y postgresql redis-server rabbitmq-server caddy git curl rsync

# Node 22
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
sudo corepack enable

# uv (Python package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### Tạo database và broker

```bash
sudo -u postgres psql -c "CREATE USER gtinx_plane WITH PASSWORD 'doi-mat-khau-nay';"
sudo -u postgres psql -c "CREATE DATABASE gtinx_plane OWNER gtinx_plane;"

sudo rabbitmqctl add_user gtinx_plane doi-mat-khau-nay
sudo rabbitmqctl add_vhost gtinx_plane
sudo rabbitmqctl set_permissions -p gtinx_plane gtinx_plane ".*" ".*" ".*"
```

Nếu dùng MinIO self-host, cài thêm MinIO (hoặc Silo) và tạo bucket `uploads`.

---

## 3. Cài đặt

### Bước 1 — Đưa code lên máy chủ

```bash
sudo mkdir -p /opt/gtinx-plane
sudo rsync -a --exclude node_modules --exclude .git ./ /opt/gtinx-plane/
sudo useradd --system --home-dir /opt/gtinx-plane --shell /usr/sbin/nologin gtinx
sudo chown -R gtinx:gtinx /opt/gtinx-plane
```

### Bước 2 — Cài dependency Python

```bash
sudo -u gtinx bash -lc '
  cd /opt/gtinx-plane/apps/api
  uv sync --locked --no-default-groups --group production
'
```

Virtualenv được tạo tại `/opt/gtinx-plane/apps/api/.venv`; unit file đã trỏ `PATH` vào đó.

### Bước 3 — Build frontend và realtime server

Các biến `VITE_*` được **nhúng vào bundle lúc build**, không đọc lúc chạy. Để trống các
`VITE_*_BASE_URL` nghĩa là frontend gọi API **same-origin** qua proxy (khuyến nghị).

```bash
sudo -u gtinx bash -lc '
  cd /opt/gtinx-plane
  export VITE_API_BASE_URL=""
  export VITE_WEB_BASE_URL=""
  export VITE_ADMIN_BASE_URL=""
  export VITE_ADMIN_BASE_PATH="/god-mode"
  export VITE_SPACE_BASE_URL=""
  export VITE_SPACE_BASE_PATH="/spaces"
  export VITE_LIVE_BASE_URL=""
  export VITE_LIVE_BASE_PATH="/live"
  pnpm install --frozen-lockfile
  pnpm turbo run build --filter=web --filter=admin --filter=space --filter=live
'
```

Kết quả:

```
apps/web/build/client      apps/admin/build/client
apps/space/build           apps/live/dist
```

### Bước 4 — Cài unit, Caddyfile, env

```bash
sudo bash /opt/gtinx-plane/deployments/systemd/install.sh
```

Script này:

- tạo user hệ thống `gtinx` (nếu chưa có)
- copy unit vào `/etc/systemd/system/`, Caddyfile vào `/etc/gtinx-plane/caddy/`
- tạo `/etc/gtinx-plane/{api,live,proxy}.env` từ file mẫu (**không ghi đè** file đã tồn tại)

### Bước 5 — Cấu hình

```bash
sudoedit /etc/gtinx-plane/api.env
sudoedit /etc/gtinx-plane/live.env
sudoedit /etc/gtinx-plane/proxy.env
```

Biến bắt buộc:

| File        | Biến                                                                                   |
| ----------- | -------------------------------------------------------------------------------------- |
| `api.env`   | `SECRET_KEY`, `DATABASE_URL`, `REDIS_URL`, `RABBITMQ_*`, `AWS_*`, `WEB_URL`, `CORS_ALLOWED_ORIGINS` |
| `api.env`   | `LIVE_SERVER_SECRET_KEY` (phải **trùng** với `live.env`)                                |
| `live.env`  | `LIVE_SERVER_SECRET_KEY`, `REDIS_URL`, `API_BASE_URL`                                   |
| `proxy.env` | `SITE_ADDRESS` (`:80`, hoặc `domain.example.com` để Caddy tự xin chứng chỉ)             |

Sinh secret:

```bash
python3 -c "from django.utils.crypto import get_random_secret_key; print(get_random_secret_key())"
```

Nếu dùng MinIO trên cùng máy: đặt `USE_MINIO=1` trong `api.env` và bỏ comment 2 dòng
`reverse_proxy /uploads` trong `/etc/gtinx-plane/caddy/proxy.Caddyfile`.

### Bước 6 — Khởi động

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gtinx-plane-migrate gtinx-plane-api gtinx-plane-worker gtinx-plane-beat \
  gtinx-plane-live gtinx-plane-space gtinx-plane-web gtinx-plane-admin gtinx-plane-proxy
```

### Bước 7 — Kiểm tra

```bash
systemctl status gtinx-plane-api gtinx-plane-worker gtinx-plane-beat gtinx-plane-live \
  gtinx-plane-space gtinx-plane-web gtinx-plane-admin gtinx-plane-proxy

curl -fsS http://127.0.0.1:8000/api/instances/ >/dev/null && echo "api OK"
curl -fsS http://127.0.0.1:3200/ >/dev/null           && echo "web OK"
curl -fsS http://127.0.0.1:3201/god-mode/ >/dev/null  && echo "admin OK"
curl -fsS http://127.0.0.1:3202/spaces/ >/dev/null    && echo "space OK"
```

Truy cập `http(s)://<domain>/` để sử dụng và `/god-mode/` cho trang quản trị instance.

---

## 4. Vận hành

```bash
# Trạng thái
systemctl status gtinx-plane-api

# Log
journalctl -u gtinx-plane-api -f
journalctl -u gtinx-plane-worker -f
journalctl -u gtinx-plane-proxy -n 200

# Khởi động lại theo thứ tự an toàn
sudo systemctl restart gtinx-plane-migrate
sudo systemctl restart gtinx-plane-api gtinx-plane-worker gtinx-plane-beat \
  gtinx-plane-live gtinx-plane-space gtinx-plane-web gtinx-plane-admin gtinx-plane-proxy

# Nạp lại cấu hình Caddy (không downtime)
sudo systemctl reload gtinx-plane-proxy
```

### Nâng cấp phiên bản

```bash
sudo systemctl stop gtinx-plane-proxy gtinx-plane-web gtinx-plane-admin gtinx-plane-space gtinx-plane-live \
  gtinx-plane-api gtinx-plane-worker gtinx-plane-beat

sudo -u gtinx bash -lc '
  cd /opt/gtinx-plane
  git pull
  pnpm install --frozen-lockfile
  export VITE_ADMIN_BASE_PATH=/god-mode VITE_SPACE_BASE_PATH=/spaces VITE_LIVE_BASE_PATH=/live
  pnpm turbo run build --filter=web --filter=admin --filter=space --filter=live
'
sudo -u gtinx bash -lc 'cd /opt/gtinx-plane/apps/api && uv sync --locked --no-default-groups --group production'

sudo systemctl start gtinx-plane-migrate
sudo systemctl start gtinx-plane-api gtinx-plane-worker gtinx-plane-beat \
  gtinx-plane-live gtinx-plane-space gtinx-plane-web gtinx-plane-admin gtinx-plane-proxy
```

### Backup

```bash
# Database
sudo -u postgres pg_dump -Fc plane > /var/backups/plane-$(date +%F).dump

# File upload (nếu dùng MinIO local)
sudo rsync -a /var/lib/minio/ /var/backups/minio-$(date +%F)/

# Cấu hình
sudo tar czf /var/backups/plane-config-$(date +%F).tgz /etc/gtinx-plane
```

---

## 5. Xử lý sự cố

| Triệu chứng                              | Nguyên nhân thường gặp                                                        |
| ---------------------------------------- | ----------------------------------------------------------------------------- |
| `gtinx-plane-api` exit ngay, log báo `GUNICORN_WORKERS` | thiếu biến trong `/etc/gtinx-plane/api.env`                                 |
| API 500 `no such table`                  | `gtinx-plane-migrate` chưa chạy xong — `systemctl status gtinx-plane-migrate`              |
| 502 ở `/api/*`                           | API không listen cổng `8000` — kiểm tra `ss -lntp \| grep 8000`                |
| Web trả 404 toàn bộ                      | chưa build web, hoặc `root` trong `web.Caddyfile` sai đường dẫn                |
| `/god-mode/` trắng trang                 | build admin thiếu `VITE_ADMIN_BASE_PATH=/god-mode`                             |
| `/spaces/` lỗi 500                        | `gtinx-plane-space` không chạy, hoặc thiếu `apps/space/build/server/index.js`        |
| WebSocket `/live` không kết nối          | `gtinx-plane-live` dừng, hoặc `LIVE_SERVER_SECRET_KEY` lệch giữa `api.env` và `live.env` |
| Upload file thất bại                     | `AWS_*` / `USE_MINIO` sai, hoặc route `/uploads` trong proxy bị comment        |
| Caddy báo lỗi TLS                        | `SITE_ADDRESS` sai, DNS chưa trỏ về máy, hoặc cổng 80/443 bị chặn              |
| Unit lỗi `status=203/EXEC`               | sai đường dẫn trong `ExecStart` — kiểm tra `which node`, `which caddy`         |
| Log Caddy báo `no such file` Caddyfile   | chưa chạy `install.sh`, hoặc đã sửa `GTINX_DIR` khi cài                        |

Xem log chi tiết:

```bash
journalctl -xeu gtinx-plane-api --no-pager | tail -50
```

---

## 6. Bảo mật

- `/etc/gtinx-plane/*.env` được đặt quyền `0640 root:plane` — secret không lộ cho user khác.
- Các unit chạy bằng user `plane`, có `NoNewPrivileges`, `ProtectSystem`, `PrivateTmp`.
  Nếu đặt log/upload ngoài `/opt/gtinx-plane`, thêm đường dẫn đó vào `ReadWritePaths=`.
- Chỉ `gtinx-plane-proxy` được bind cổng < 1024 qua `AmbientCapabilities=CAP_NET_BIND_SERVICE`.
- Đặt `DEBUG=0` và `SECRET_KEY` riêng cho từng môi trường; không dùng giá trị mặc định.
- Nên giới hạn truy cập PostgreSQL / Redis / RabbitMQ trong `127.0.0.1` hoặc firewall nội bộ.

---

## 7. Cấu trúc thư mục liên quan

```
deployments/systemd/          # unit, Caddyfile, env mẫu, install.sh, hướng dẫn chi tiết
apps/api/                     # Django backend (Python) + bin/ entrypoints
apps/web/                     # frontend chính (build → build/client)
apps/admin/                   # trang quản trị (build → build/client)
apps/space/                   # trang public (build → build/server + build/client)
apps/live/                    # realtime server (build → dist)
apps/proxy/                   # Caddyfile dùng cho bản Docker
docker-compose.yml            # cách chạy bằng Docker (không dùng trong tài liệu này)
```

Hướng dẫn chi tiết hơn (từng biến môi trường, cấu hình MinIO, chuyển đổi từ Docker) nằm trong
[`deployments/systemd/README.md`](./deployments/systemd/README.md).

---

## License

Xem [`LICENSE.txt`](./LICENSE.txt) và [`COPYRIGHT.txt`](./COPYRIGHT.txt).
