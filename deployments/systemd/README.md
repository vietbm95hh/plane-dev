# Chạy gtinx-plane bằng systemd (không dùng Docker)

Bộ file này chạy **đầy đủ** gtinx-plane Community trên một máy Linux, dùng `systemd` thay cho
`docker compose`. Các file Docker trong repo **vẫn được giữ nguyên** — bạn có thể dùng
lại bất cứ lúc nào; hai cách chạy không ảnh hưởng nhau.

## Kiến trúc

| Unit | Thành phần | Cổng (localhost) | Ghi chú |
|---|---|---|---|
| `gtinx-plane-migrate.service` | Django migrate (`oneshot`) | – | chạy trước api/worker/beat |
| `gtinx-plane-api.service` | Django API + gunicorn/uvicorn | `8000` | `apps/api` |
| `gtinx-plane-worker.service` | Celery worker | – | `apps/api` |
| `gtinx-plane-beat.service` | Celery beat | – | `apps/api` |
| `gtinx-plane-live.service` | Hocuspocus realtime | `3100` | `apps/live/dist` |
| `gtinx-plane-space.service` | Space (React Router SSR) | `3202` | `apps/space/build` |
| `gtinx-plane-web.service` | Web SPA (Caddy static) | `3200` | `apps/web/build/client` |
| `gtinx-plane-admin.service` | Admin god-mode (Caddy static) | `3201` | `apps/admin/build/client` |
| `gtinx-plane-proxy.service` | Caddy reverse proxy + TLS | `80/443` | `deployments/systemd/caddy/proxy.Caddyfile` |

`apps/proxy/Caddyfile.ce` dùng tên container (`web:3000`, `api:8000`…). Trên host, các service
dùng chung network namespace nên **mỗi service phải một cổng riêng**; vì vậy bản Caddyfile
trong `deployments/systemd/caddy/` trỏ tới `127.0.0.1:<port>`.

> Các script `apps/api/bin/docker-entrypoint-*.sh` **được tái sử dụng nguyên vẹn**. Chúng chỉ là
> bash + gunicorn/celery, không phụ thuộc Docker. Tên file có chữ "docker" nhưng chạy tốt ngoài container.

## Yêu cầu

- Ubuntu 22.04/24.04 hoặc Debian 12 (systemd)
- **Node.js >= 22.22** + `corepack`/`pnpm 10`
- **Python 3.12** + [uv](https://docs.astral.sh/uv/)
- **PostgreSQL 15+**, **Redis/Valkey 7+**, **RabbitMQ 3.13+**
- Object storage: S3 (AWS/R2/…) hoặc MinIO/Silo self-host
- **Caddy 2.11+** (`caddy` từ repo chính thức)

```bash
sudo apt install -y postgresql redis-server rabbitmq-server caddy git curl
# Node 22 + pnpm
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs
sudo corepack enable && sudo corepack prepare pnpm@latest --activate
# uv
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Tạo database/Redis/RabbitMQ (ví dụ):

```bash
sudo -u postgres psql -c "CREATE USER gtinx_plane WITH PASSWORD 'plane';"
sudo -u postgres psql -c "CREATE DATABASE gtinx_plane OWNER gtinx_plane;"
sudo rabbitmqctl add_user gtinx_plane plane
sudo rabbitmqctl add_vhost gtinx_plane
sudo rabbitmqctl set_permissions -p gtinx_plane gtinx_plane ".*" ".*" ".*"
```

## Cài đặt

### 1. Đưa code lên máy chủ

```bash
sudo mkdir -p /opt/gtinx-plane
sudo rsync -a --exclude node_modules --exclude .git ./ /opt/gtinx-plane/
sudo useradd --system --home-dir /opt/gtinx-plane --shell /usr/sbin/nologin gtinx
sudo chown -R gtinx:gtinx /opt/gtinx-plane
```

### 2. Backend (Python, dùng `uv`)

```bash
sudo -u gtinx bash -lc '
  cd /opt/gtinx-plane/apps/api
  uv sync --locked --no-default-groups --group production
'
```

`uv sync` tạo virtualenv tại `/opt/gtinx-plane/apps/api/.venv`; unit file đã trỏ `PATH` vào đó.

### 3. Build frontend + live

Các biến `VITE_*` là **build-time** (nhúng vào bundle), phải export trước khi build.
Để trống các `VITE_*_BASE_URL` để FE gọi API **same-origin** qua proxy (khuyến nghị).

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

Kết quả: `apps/web/build/client`, `apps/admin/build/client`, `apps/space/build`, `apps/live/dist`.

### 4. Cấu hình

```bash
sudo bash ./deployments/systemd/install.sh
```

Script tạo user `plane`, copy unit vào `/etc/systemd/system/`, Caddyfile vào `/etc/gtinx-plane/caddy/`,
và các file env mẫu vào `/etc/gtinx-plane/`. Sau đó sửa:

- `/etc/gtinx-plane/api.env` — `SECRET_KEY`, `DATABASE_URL`, `REDIS_URL`, `RABBITMQ_*`, `AWS_*`, `WEB_URL`
- `/etc/gtinx-plane/live.env` — `LIVE_SERVER_SECRET_KEY` (**phải trùng** với api.env), `REDIS_URL`
- `/etc/gtinx-plane/proxy.env` — `SITE_ADDRESS` (`:80`, hoặc `plane.example.com` để bật HTTPS tự động)

Sinh secret:

```bash
python3 -c "from django.utils.crypto import get_random_secret_key; print(get_random_secret_key())"
```

Nếu dùng MinIO trên cùng máy: đặt `USE_MINIO=1` và bỏ comment 2 dòng `reverse_proxy /uploads` trong
`/etc/gtinx-plane/caddy/proxy.Caddyfile`.

### 5. Khởi động

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gtinx-plane-migrate gtinx-plane-api gtinx-plane-worker gtinx-plane-beat \
  gtinx-plane-live gtinx-plane-space gtinx-plane-web gtinx-plane-admin gtinx-plane-proxy
```

Kiểm tra:

```bash
systemctl status gtinx-plane-api gtinx-plane-worker gtinx-plane-beat gtinx-plane-live gtinx-plane-space gtinx-plane-web gtinx-plane-admin gtinx-plane-proxy
curl -fsS http://127.0.0.1:8000/api/instances/   # API
curl -fsS http://127.0.0.1:3200/ >/dev/null      # web
curl -fsS http://127.0.0.1:3202/spaces/ >/dev/null
curl -fsS http://127.0.0.1:3201/god-mode/ >/dev/null
```

Mở `http://<IP hoặc domain>` để dùng, `/god-mode/` cho admin.

## Cài ở đường dẫn khác `/opt`

Mặc định mọi unit trỏ tới `/opt/gtinx-plane`. Có thể đổi bằng biến môi trường khi chạy installer.

### Trường hợp A — giữ user riêng `gtinx` (khuyến nghị)

```bash
sudo GTINX_DIR=/root/cts/service/plane-dev GTINX_PROTECT_HOME=no \
  bash /root/cts/service/plane-dev/deployments/systemd/install.sh

# cho user gtinx đi xuyên qua /root (chỉ cần +x, không cần đọc nội dung)
sudo chmod o+x /root
sudo chown -R gtinx:gtinx /root/cts/service/plane-dev
```

`ProtectHome=no` là bắt buộc: mặc định `ProtectHome=yes` khiến systemd **che toàn bộ `/root`**,
service sẽ không thấy code dù chạy bằng user nào.

### Trường hợp B — chạy service bằng `root` (nhanh, chỉ nên dùng cho dev)

```bash
sudo GTINX_DIR=/root/cts/service/plane-dev GTINX_USER=root GTINX_PROTECT_HOME=no \
  bash /root/cts/service/plane-dev/deployments/systemd/install.sh
```

Không cần `chmod /root`, không cần `chown`. Đổi lại, mọi service chạy với quyền cao nhất —
không dùng cho production.

Sau khi cài lại unit, luôn chạy:

```bash
sudo systemctl daemon-reload
systemctl show -p WorkingDirectory -p User -p ProtectHome gtinx-plane-api
```

**Vì sao `/opt` vẫn tốt hơn:** `/root` là home của root, mọi công cụ (backup, log rotate, rsync)
đều mặc định bỏ qua nó; và `ProtectHome=yes` — lớp hardening của unit — phải tắt.

## Vận hành

```bash
journalctl -u gtinx-plane-api -f          # log API
journalctl -u gtinx-plane-worker -f       # log Celery
journalctl -u gtinx-plane-proxy -n 200    # log Caddy (TLS, 502…)
systemctl restart gtinx-plane-api gtinx-plane-worker gtinx-plane-beat
```

Nâng cấp:

```bash
sudo systemctl stop gtinx-plane-proxy gtinx-plane-web gtinx-plane-admin gtinx-plane-space gtinx-plane-live \
  gtinx-plane-api gtinx-plane-worker gtinx-plane-beat
sudo -u gtinx bash -lc 'cd /opt/gtinx-plane && git pull && pnpm install --frozen-lockfile && pnpm turbo run build --filter=web --filter=admin --filter=space --filter=live'
sudo -u gtinx bash -lc 'cd /opt/gtinx-plane/apps/api && uv sync --locked --no-default-groups --group production'
sudo systemctl restart gtinx-plane-migrate && sudo systemctl restart gtinx-plane-api gtinx-plane-worker gtinx-plane-beat \
  gtinx-plane-live gtinx-plane-space gtinx-plane-web gtinx-plane-admin gtinx-plane-proxy
```

## Xử lý sự cố

| Triệu chứng | Nguyên nhân thường gặp |
|---|---|
| `gtinx-plane-api` exit ngay, log `GUNICORN_WORKERS` | thiếu biến trong `/etc/gtinx-plane/api.env` |
| API 500 `no such table` | `gtinx-plane-migrate` chưa chạy xong — `systemctl status gtinx-plane-migrate` |
| Web 404 toàn bộ | chưa build web, hoặc `root` trong `web.Caddyfile` sai đường dẫn |
| `/god-mode/` trắng trang | build admin thiếu `VITE_ADMIN_BASE_PATH=/god-mode` |
| 502 ở `/api/*` | API không listen trên `8000` (`ss -lntp \| grep 8000`) |
| Upload lỗi | `AWS_S3_*`/`USE_MINIO` sai, hoặc block `/uploads` trong proxy bị comment |
| WebSocket `/live` lỗi | `gtinx-plane-live` không chạy, hoặc `LIVE_SERVER_SECRET_KEY` lệch giữa api/live |

## Bảo mật

- `/etc/gtinx-plane/*.env` đã là `0640 root:plane`, không lộ secret cho user khác.
- Các unit có `NoNewPrivileges`, `ProtectSystem`, `PrivateTmp`; nếu bạn đặt upload/log ngoài
  `/opt/gtinx-plane`, thêm đường dẫn đó vào `ReadWritePaths=`.
- `plane-*.service` chạy bằng user `plane`, chỉ `gtinx-plane-proxy` được bind cổng < 1024
  qua `AmbientCapabilities=CAP_NET_BIND_SERVICE`.
