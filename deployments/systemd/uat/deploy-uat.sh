#!/usr/bin/env bash
# =============================================================================
# gtinx-plane - deploy UAT lên Ubuntu 22.04/24.04 bằng systemd
#
#   sudo bash deployments/systemd/uat/deploy-uat.sh
#
# Cấu hình (tuỳ chọn): tạo deployments/systemd/uat/deploy-uat.conf
#   xem deploy-uat.conf.example
#
# Script idempotent: chạy lại để nâng cấp / sửa cấu hình.
# Secret được sinh 1 lần và lưu tại /etc/gtinx-plane/uat-secrets.env
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

CONF="${CONF:-$SCRIPT_DIR/deploy-uat.conf}"
if [[ -f "$CONF" ]]; then
	# shellcheck disable=SC1090
	set -a
	. "$CONF"
	set +a
fi

GTINX_DIR="${GTINX_DIR:-/opt/gtinx-plane}"
GTINX_USER="${GTINX_USER:-gtinx}"
SITE_ADDRESS="${SITE_ADDRESS:-:80}" # ":80" = HTTP theo IP; "uat.example.com" = HTTPS tự động
WITH_MINIO="${WITH_MINIO:-1}"       # 1 = cài MinIO local; 0 = dùng S3 ngoài
SKIP_PACKAGES="${SKIP_PACKAGES:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
GUNICORN_WORKERS="${GUNICORN_WORKERS:-}"
# Silo = fork MinIO đang được maintain (MinIO community đã ngừng phát hành binary)
MINIO_FLAVOR="${MINIO_FLAVOR:-silo}"
MINIO_BINARY_URL="${MINIO_BINARY_URL:-https://github.com/minio/minio/releases/download/RELEASE.2025-09-07T16-13-09Z/minio.linux-amd64.RELEASE.2025-09-07T16-13-09Z}"
S3_BUCKET="${S3_BUCKET:-uploads}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_ENDPOINT="${S3_ENDPOINT:-http://127.0.0.1:9000}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
# 1 = tự tắt nginx/apache2/httpd đang chiếm cổng 80 (chỉ bật khi chắc chắn không cần chúng)
DISABLE_CONFLICTING_SERVICES="${DISABLE_CONFLICTING_SERVICES:-0}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
OS_USER_HOME="$GTINX_DIR"

ENV_DIR=/etc/gtinx-plane
SECRETS_FILE="$ENV_DIR/uat-secrets.env"
MINIO_DATA=/var/lib/gtinx-plane/minio
SERVICES=(
	gtinx-plane-migrate
	gtinx-plane-api
	gtinx-plane-worker
	gtinx-plane-beat
	gtinx-plane-live
	gtinx-plane-space
	gtinx-plane-web
	gtinx-plane-admin
	gtinx-plane-proxy
)

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok() { printf '  \033[0;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '  \033[0;33m! %s\033[0m\n' "$*"; }
die() {
	printf '  \033[0;31m✗ %s\033[0m\n' "$*" >&2
	exit 1
}

[[ $EUID -eq 0 ]] || die "Phải chạy bằng root/sudo."
[[ -f "$REPO_ROOT/package.json" ]] || die "Không thấy package.json - hãy chạy script từ trong repo."
command -v systemctl >/dev/null || die "Không có systemd trên máy này."

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$HOST_IP" ]] || HOST_IP=127.0.0.1

# shellcheck disable=SC1091
. /etc/os-release
OS_CODENAME="${VERSION_CODENAME:-}"

if [[ -n "${APP_URL:-}" ]]; then
	:
elif [[ "$SITE_ADDRESS" == http://* || "$SITE_ADDRESS" == https://* ]]; then
	APP_URL="$SITE_ADDRESS"
elif [[ "$SITE_ADDRESS" == :* || "$SITE_ADDRESS" == \[* || "$SITE_ADDRESS" == [0-9]* ]]; then
	APP_URL="http://$HOST_IP"
else
	APP_URL="https://$SITE_ADDRESS"
fi
APP_URL="${APP_URL%/}"

# -----------------------------------------------------------------------------
# 1. Gói hệ thống
# -----------------------------------------------------------------------------
install_postgres() {
	local cur=""
	if command -v psql >/dev/null 2>&1; then
		cur="$(psql --version | grep -oP '\) \K[0-9]+' || true)"
	fi
	if [[ -n "$cur" ]] && systemctl list-unit-files 2>/dev/null | grep -q '^postgresql.service'; then
		if (( cur < 15 )); then
			die "PostgreSQL $cur < 15. Cài PostgreSQL 16 theo hướng dẫn PGDG (https://www.postgresql.org/download/linux/ubuntu/) hoặc trỏ DATABASE_URL sang server PG khác, rồi chạy lại với SKIP_PACKAGES=1."
		fi
		ok "PostgreSQL $cur đã có sẵn"
		return 0
	fi
	if [[ "$OS_CODENAME" == "jammy" ]]; then
		# Ubuntu 22.04 chỉ có PG 14 -> dùng PGDG để lấy PG 16
		install -d /usr/share/postgresql-common/pgdg
		curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
			https://www.postgresql.org/media/keys/ACCC4CF8.asc
		echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${OS_CODENAME}-pgdg main" \
			>/etc/apt/sources.list.d/pgdg.list
		apt-get update -y
		apt-get install -y --no-install-recommends postgresql-16
		ok "Đã cài PostgreSQL 16 (PGDG)"
	else
		apt-get install -y --no-install-recommends postgresql
		ok "Đã cài PostgreSQL từ Ubuntu repo"
	fi
}

install_packages() {
	if [[ "$SKIP_PACKAGES" == "1" ]]; then
		warn "SKIP_PACKAGES=1 - bỏ qua apt"
		return 0
	fi
	log "1/12 Cài gói hệ thống"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -y
	# psycopg-c được build từ source => cần compiler + pg_config
	apt-get install -y --no-install-recommends \
		redis-server rabbitmq-server \
		git curl rsync ca-certificates gnupg build-essential libpq-dev \
		debian-keyring debian-archive-keyring apt-transport-https

	install_postgres
	# Caddy 2.11+ từ repo chính thức (apt của Ubuntu quá cũ)
	if ! caddy version 2>/dev/null | grep -qE '^v?2\.(1[1-9]|[2-9][0-9])'; then
		curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' |
			gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
		curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
			>/etc/apt/sources.list.d/caddy-stable.list
		apt-get update -y
		apt-get install -y --no-install-recommends caddy
	fi
	# Caddy mặc định chiếm :80 - tắt đi, ta dùng gtinx-plane-proxy
	if systemctl list-unit-files | grep -q '^caddy.service'; then
		systemctl disable --now caddy.service >/dev/null 2>&1 || true
	fi

	# Node 22 (repo yêu cầu >= 22.22.0)
	local node_v="" need_node=0
	if command -v node >/dev/null 2>&1; then
		node_v="$(node -v | sed 's/^v//')"
		if [[ "$(printf '22.22.0\n%s\n' "$node_v" | sort -V | head -1)" != "22.22.0" ]]; then
			need_node=1
		fi
	else
		need_node=1
	fi
	if [[ "$need_node" == "1" ]]; then
		curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
		apt-get install -y nodejs
	fi
	node_v="$(node -v | sed 's/^v//')"
	if [[ "$(printf '22.22.0\n%s\n' "$node_v" | sort -V | head -1)" != "22.22.0" ]]; then
		die "Node $node_v quá cũ, cần >= 22.22.0"
	fi
	ok "node $(node -v), caddy $(caddy version | awk '{print $1}')"
}

# -----------------------------------------------------------------------------
# 2. User + thư mục
# -----------------------------------------------------------------------------
create_user() {
	log "2/12 Tạo user hệ thống và thư mục"
	if ! id -u "$GTINX_USER" >/dev/null 2>&1; then
		useradd --system --home-dir "$GTINX_DIR" --shell /usr/sbin/nologin "$GTINX_USER"
		ok "Đã tạo user $GTINX_USER"
	else
		ok "User $GTINX_USER đã tồn tại"
	fi
	install -d -m 0755 -o "$GTINX_USER" -g "$GTINX_USER" "$GTINX_DIR"
	install -d -m 0750 -o root -g "$GTINX_USER" "$ENV_DIR"
	install -d -m 0750 -o root -g "$GTINX_USER" "$ENV_DIR/caddy"
	install -d -m 0750 -o "$GTINX_USER" -g "$GTINX_USER" /var/lib/gtinx-plane
	install -d -m 0750 -o "$GTINX_USER" -g "$GTINX_USER" /var/lib/gtinx-plane/caddy
	if [[ "$GTINX_DIR" == /root/* ]]; then
		# user gtinx cần đi xuyên qua /root (chỉ +x, không đọc được nội dung)
		chmod o+x /root
	fi
}

# -----------------------------------------------------------------------------
# 3. Secret (giữ nguyên qua các lần chạy)
# -----------------------------------------------------------------------------
load_secrets() {
	log "3/12 Secret"
	if [[ ! -f "$SECRETS_FILE" ]]; then
		(
			umask 077
			{
				echo "SECRET_KEY=$(openssl rand -hex 32)"
				echo "LIVE_SERVER_SECRET_KEY=$(openssl rand -hex 32)"
				echo "PG_PASSWORD=$(openssl rand -hex 16)"
				echo "MQ_PASSWORD=$(openssl rand -hex 16)"
				echo "S3_ACCESS_KEY=plane$(openssl rand -hex 8)"
				echo "S3_SECRET_KEY=$(openssl rand -hex 24)"
			} >"$SECRETS_FILE"
		)
		chown root:root "$SECRETS_FILE"
		chmod 0600 "$SECRETS_FILE"
		ok "Đã sinh $SECRETS_FILE (backup file này!)"
	else
		ok "Dùng lại $SECRETS_FILE"
	fi
	# shellcheck disable=SC1090
	set -a
	. "$SECRETS_FILE"
	set +a
	[[ -n "${SECRET_KEY:-}" && -n "${LIVE_SERVER_SECRET_KEY:-}" ]] || die "Secret file thiếu SECRET_KEY"
}

# -----------------------------------------------------------------------------
# 4. Đồng bộ code
# -----------------------------------------------------------------------------
sync_code() {
	log "4/12 Đồng bộ code vào $GTINX_DIR"
	if [[ "$(readlink -f "$REPO_ROOT")" == "$(readlink -f "$GTINX_DIR")" ]]; then
		ok "Đang chạy trực tiếp trong $GTINX_DIR - bỏ qua rsync"
	else
		rsync -a \
			--exclude '.git' --exclude 'node_modules' --exclude '.venv' \
			--exclude 'build' --exclude 'dist' --exclude '.turbo' \
			--exclude '.local' --exclude '.cache' --exclude '.env' --exclude '.env.*' \
			"$REPO_ROOT"/ "$GTINX_DIR"/
		ok "Đã copy code"
	fi
	chown -R "$GTINX_USER:$GTINX_USER" "$GTINX_DIR"
}

# -----------------------------------------------------------------------------
# 5. File env cho systemd
# -----------------------------------------------------------------------------
write_env() { # $1 = target, stdin = nội dung
	local target=$1 tmp
	tmp="$(mktemp)"
	cat >"$tmp"
	install -m 0640 -o root -g "$GTINX_USER" "$tmp" "$target"
	rm -f "$tmp"
}

write_envs() {
	log "5/12 Ghi cấu hình $ENV_DIR"
	if [[ -z "$GUNICORN_WORKERS" ]]; then
		GUNICORN_WORKERS=$(( $(nproc) * 2 + 1 ))
		if (( GUNICORN_WORKERS > 8 )); then
			GUNICORN_WORKERS=8
		fi
	fi
	# S3 ngoài: cho phép override bằng AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY trong conf
	local aws_key="${AWS_ACCESS_KEY_ID:-$S3_ACCESS_KEY}"
	local aws_secret="${AWS_SECRET_ACCESS_KEY:-$S3_SECRET_KEY}"

	# Redis có mật khẩu: phải URL-encode (Cts@12345 -> Cts%4012345)
	local redis_auth="" redis_url
	if [[ -n "$REDIS_PASSWORD" ]]; then
		local enc
		enc="$(REDIS_PW="$REDIS_PASSWORD" python3 -c 'import os,urllib.parse;print(urllib.parse.quote(os.environ["REDIS_PW"], safe=""))' 2>/dev/null || true)"
		[[ -n "$enc" ]] || die "Không URL-encode được REDIS_PASSWORD (cần python3)."
		redis_auth=":$enc@"
	fi
	redis_url="redis://${redis_auth}${REDIS_HOST}:${REDIS_PORT}/"

	if [[ ! -f "$ENV_DIR/api.env" ]]; then
		write_env "$ENV_DIR/api.env" <<EOF
# gtinx-plane API / worker / beat / migrate (sinh bởi deploy-uat.sh)
DEBUG=0
DOCKERIZED=0
SECRET_KEY="$SECRET_KEY"
WEB_URL="$APP_URL"
CORS_ALLOWED_ORIGINS="$APP_URL"
FILE_SIZE_LIMIT=5242880
SIGNED_URL_EXPIRATION=3600

POSTGRES_USER="gtinx_plane"
POSTGRES_PASSWORD="$PG_PASSWORD"
POSTGRES_HOST="127.0.0.1"
POSTGRES_DB="gtinx_plane"
POSTGRES_PORT=5432
DATABASE_URL="postgresql://gtinx_plane:$PG_PASSWORD@127.0.0.1:5432/gtinx_plane"

REDIS_HOST="$REDIS_HOST"
REDIS_PORT="$REDIS_PORT"
REDIS_URL="$redis_url"
REDIS_SSL_CERT_REQS="required"
REDIS_SSL_CA_CERTS=""

RABBITMQ_HOST="127.0.0.1"
RABBITMQ_PORT="5672"
RABBITMQ_USER="gtinx_plane"
RABBITMQ_PASSWORD="$MQ_PASSWORD"
RABBITMQ_VHOST="gtinx_plane"

AWS_REGION="$S3_REGION"
AWS_ACCESS_KEY_ID="$aws_key"
AWS_SECRET_ACCESS_KEY="$aws_secret"
AWS_S3_ENDPOINT_URL="$S3_ENDPOINT"
AWS_S3_BUCKET_NAME="$S3_BUCKET"
BUCKET_NAME="$S3_BUCKET"
USE_MINIO=$WITH_MINIO

GUNICORN_WORKERS=$GUNICORN_WORKERS
PORT=8000

ADMIN_BASE_URL="$APP_URL"
ADMIN_BASE_PATH="/god-mode"
SPACE_BASE_URL="$APP_URL"
SPACE_BASE_PATH="/spaces"
APP_BASE_URL="$APP_URL"
APP_BASE_PATH=""
LIVE_BASE_URL="$APP_URL"
LIVE_BASE_PATH="/live"

LIVE_SERVER_SECRET_KEY="$LIVE_SERVER_SECRET_KEY"

HARD_DELETE_AFTER_DAYS=60
MINIO_ENDPOINT_SSL=0
API_KEY_RATE_LIMIT="60/minute"
EOF
		ok "Đã tạo $ENV_DIR/api.env"
	else
		warn "Giữ nguyên $ENV_DIR/api.env (sửa tay nếu cần)"
	fi

	if [[ ! -f "$ENV_DIR/live.env" ]]; then
		write_env "$ENV_DIR/live.env" <<EOF
# gtinx-plane live server
PORT=3100
API_BASE_URL="http://127.0.0.1:8000"
WEB_BASE_URL="$APP_URL"
LIVE_BASE_URL="$APP_URL"
LIVE_BASE_PATH="/live"
LIVE_SERVER_SECRET_KEY="$LIVE_SERVER_SECRET_KEY"
REDIS_HOST="$REDIS_HOST"
REDIS_PORT=$REDIS_PORT
REDIS_URL="$redis_url"
EOF
		ok "Đã tạo $ENV_DIR/live.env"
	else
		warn "Giữ nguyên $ENV_DIR/live.env"
	fi

	if [[ ! -f "$ENV_DIR/proxy.env" ]]; then
		write_env "$ENV_DIR/proxy.env" <<EOF
# gtinx-plane reverse proxy (Caddy)
SITE_ADDRESS="$SITE_ADDRESS"
FILE_SIZE_LIMIT=5242880
BUCKET_NAME="$S3_BUCKET"
EOF
		ok "Đã tạo $ENV_DIR/proxy.env"
	else
		warn "Giữ nguyên $ENV_DIR/proxy.env"
	fi
}

# -----------------------------------------------------------------------------
# 6. Object storage: Silo (fork MinIO, mặc định) hoặc MinIO
# -----------------------------------------------------------------------------
silo_download_url() { # $1 = amd64|arm64
	local arch=$1 url="" pinned
	pinned="https://github.com/pgsty/silo/releases/download/RELEASE.2026-11-12T00-00-00Z/silo_20261112000000.0.0_linux_${arch}.tar.gz"
	if command -v python3 >/dev/null 2>&1; then
		url="$(curl -fsSL --max-time 20 https://api.github.com/repos/pgsty/silo/releases/latest 2>/dev/null |
			SILO_ARCH="$arch" python3 -c '
import os, sys, json
arch = os.environ["SILO_ARCH"]
try:
    data = json.load(sys.stdin)
    print(next(a["browser_download_url"] for a in data["assets"]
               if a["name"].endswith("linux_" + arch + ".tar.gz")))
except Exception:
    pass
' 2>/dev/null || true)"
	fi
	printf '%s\n' "${url:-$pinned}"
}

setup_minio() {
	[[ "$WITH_MINIO" == "1" ]] || {
		warn "WITH_MINIO=0 - bỏ qua object storage (dùng S3 ngoài tại $S3_ENDPOINT)"
		return 0
	}
	log "6/12 Object storage (Silo/MinIO)"

	local arch
	case "$(uname -m)" in
		x86_64) arch=amd64 ;;
		aarch64 | arm64) arch=arm64 ;;
		*) die "Kiến trúc $(uname -m) chưa được hỗ trợ cho object storage." ;;
	esac

	local bin=""
	if [[ -x /usr/local/bin/silo ]]; then
		bin=/usr/local/bin/silo
	elif [[ -x /usr/local/bin/minio ]]; then
		bin=/usr/local/bin/minio
	fi

	if [[ -z "$bin" ]]; then
		if [[ "$MINIO_FLAVOR" == "minio" ]]; then
			curl -fsSL -o /usr/local/bin/minio "$MINIO_BINARY_URL" ||
				die "Không tải được MinIO: $MINIO_BINARY_URL (dl.min.io đã ngừng phát hành, dùng MINIO_FLAVOR=silo)"
			chmod 0755 /usr/local/bin/minio
			bin=/usr/local/bin/minio
		else
			local url tmp found
			url="$(silo_download_url "$arch")"
			tmp="$(mktemp -d)"
			curl -fsSL "$url" -o "$tmp/silo.tgz" || die "Không tải được Silo: $url"
			tar -xzf "$tmp/silo.tgz" -C "$tmp"
			found="$(find "$tmp" -type f -name silo | head -1)"
			[[ -n "$found" ]] || die "Không tìm thấy binary silo trong $url"
			install -m 0755 "$found" /usr/local/bin/silo
			rm -rf "$tmp"
			bin=/usr/local/bin/silo
			ok "Đã cài Silo (fork MinIO): $url"
		fi
	fi

	install -d -m 0750 -o "$GTINX_USER" -g "$GTINX_USER" "$MINIO_DATA"

	if [[ ! -f "$ENV_DIR/minio.env" ]]; then
		write_env "$ENV_DIR/minio.env" <<EOF
MINIO_ROOT_USER="$S3_ACCESS_KEY"
MINIO_ROOT_PASSWORD="$S3_SECRET_KEY"
EOF
	fi

	cat >/etc/systemd/system/minio.service <<EOF
[Unit]
Description=Object storage for gtinx-plane UAT (Silo/MinIO)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$GTINX_USER
Group=$GTINX_USER
EnvironmentFile=$ENV_DIR/minio.env
ExecStart=$bin server $MINIO_DATA --address 127.0.0.1:9000 --console-address 127.0.0.1:9090
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now minio.service
	systemctl restart minio.service
	ok "$bin -> 127.0.0.1:9000 (console :9090)"
}

# -----------------------------------------------------------------------------
# 7. PostgreSQL / Redis / RabbitMQ
# -----------------------------------------------------------------------------
setup_datastores() {
	log "7/12 PostgreSQL / Redis / RabbitMQ"
	systemctl enable --now postgresql redis-server rabbitmq-server

	if [[ -n "$REDIS_PASSWORD" ]] && command -v redis-cli >/dev/null 2>&1; then
		if redis-cli --no-auth-warning -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG; then
			ok "Redis auth OK ($REDIS_HOST:$REDIS_PORT)"
		else
			warn "Redis không trả PONG với REDIS_PASSWORD đã cấu hình."
			warn "  Kiểm tra: grep ^requirepass /etc/redis/redis.conf"
			warn "  Thử: redis-cli -h $REDIS_HOST -p $REDIS_PORT -a '<pass>' ping"
		fi
	fi

	if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='gtinx_plane'" | grep -q 1; then
		sudo -u postgres psql -q -c "CREATE USER gtinx_plane WITH PASSWORD '$PG_PASSWORD';"
		ok "Đã tạo role gtinx_plane"
	else
		sudo -u postgres psql -q -c "ALTER USER gtinx_plane WITH PASSWORD '$PG_PASSWORD';"
		ok "Đã cập nhật mật khẩu role gtinx_plane"
	fi
	if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='gtinx_plane'" | grep -q 1; then
		sudo -u postgres psql -q -c "CREATE DATABASE gtinx_plane OWNER gtinx_plane;"
		ok "Đã tạo database gtinx_plane"
	fi

	if rabbitmqctl list_users 2>/dev/null | awk '{print $1}' | grep -qx gtinx_plane; then
		rabbitmqctl change_password gtinx_plane "$MQ_PASSWORD" >/dev/null
	else
		rabbitmqctl add_user gtinx_plane "$MQ_PASSWORD" >/dev/null
	fi
	rabbitmqctl list_vhosts 2>/dev/null | grep -qx gtinx_plane ||
		rabbitmqctl add_vhost gtinx_plane >/dev/null
	rabbitmqctl set_permissions -p gtinx_plane gtinx_plane ".*" ".*" ".*" >/dev/null
	ok "RabbitMQ user/vhost gtinx_plane sẵn sàng"
}

# -----------------------------------------------------------------------------
# 8. Python deps (uv)
# -----------------------------------------------------------------------------
setup_python() {
	log "8/12 Python $PYTHON_VERSION + uv"
	local uv_req
	uv_req="$(awk -F'"' '/^required-version/ { split($2, a, "=="); print a[2]; exit }' \
		"$GTINX_DIR/apps/api/pyproject.toml" 2>/dev/null || true)"
	[[ -n "$uv_req" ]] || die "Không đọc được [tool.uv] required-version trong $GTINX_DIR/apps/api/pyproject.toml"
	ok "uv yêu cầu: $uv_req"

	# Lưu ý: install.sh của uv KHÔNG nhận UV_VERSION - nó luôn cài latest.
	# Vì vậy cài xong phải pin lại đúng version trong pyproject.toml.
	sudo -u "$GTINX_USER" env HOME="$OS_USER_HOME" UV_VERSION="$uv_req" bash -s <<'EOS'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

current="$(uv --version | awk '{print $2}')"
if [ "$current" != "$UV_VERSION" ]; then
  echo "==> pin uv $UV_VERSION (đang là $current)"
  if ! uv self update "$UV_VERSION"; then
    echo "!! uv self update thất bại, tải trực tiếp từ GitHub" >&2
    case "$(uname -m)" in
      x86_64) ua="x86_64-unknown-linux-gnu" ;;
      aarch64 | arm64) ua="aarch64-unknown-linux-gnu" ;;
      *) echo "!! kiến trúc $(uname -m) chưa hỗ trợ" >&2; exit 1 ;;
    esac
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$ua.tar.gz" \
      -o "$tmp/uv.tgz"
    tar -xzf "$tmp/uv.tgz" -C "$tmp"
    install -m 0755 "$tmp/uv-$ua/uv" "$HOME/.local/bin/uv"
    install -m 0755 "$tmp/uv-$ua/uvx" "$HOME/.local/bin/uvx"
    rm -rf "$tmp"
  fi
fi
uv --version
EOS

	sudo -u "$GTINX_USER" env HOME="$OS_USER_HOME" GTINX_DIR="$GTINX_DIR" PYTHON_VERSION="$PYTHON_VERSION" bash -s <<'EOS'
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$GTINX_DIR/apps/api"
uv python install "$PYTHON_VERSION"
uv sync --locked --no-default-groups --group production
EOS
	ok "Đã cài Python deps vào apps/api/.venv"
}

# -----------------------------------------------------------------------------
# 9. Build frontend + live
# -----------------------------------------------------------------------------
build_frontends() {
	if [[ "$SKIP_BUILD" == "1" ]]; then
		warn "SKIP_BUILD=1 - không build FE"
		return 0
	fi
	log "9/12 pnpm install + build (web/admin/space/live)"
	local pnpm_req
	pnpm_req="$(node -p "require('$GTINX_DIR/package.json').packageManager.split('@')[1].split('+')[0]")"
	if ! command -v pnpm >/dev/null 2>&1 || [[ "$(pnpm -v)" != "$pnpm_req" ]]; then
		npm install -g "pnpm@$pnpm_req" >/dev/null
		ok "Đã cài pnpm@$pnpm_req"
	fi

	# VITE_* là build-time -> phải export trước khi build
	sudo -u "$GTINX_USER" env HOME="$OS_USER_HOME" GTINX_DIR="$GTINX_DIR" bash -s <<'EOS'
set -euo pipefail
export CI=1 HUSKY=0 TURBO_TELEMETRY_DISABLED=1 NEXT_TELEMETRY_DISABLED=1
export VITE_API_BASE_URL=""
export VITE_WEB_BASE_URL=""
export VITE_ADMIN_BASE_URL="" VITE_ADMIN_BASE_PATH="/god-mode"
export VITE_SPACE_BASE_URL="" VITE_SPACE_BASE_PATH="/spaces"
export VITE_LIVE_BASE_URL="" VITE_LIVE_BASE_PATH="/live"
cd "$GTINX_DIR"
pnpm install --frozen-lockfile
pnpm turbo run build --filter=web --filter=admin --filter=space --filter=live
EOS
	ok "Build xong"
}

# -----------------------------------------------------------------------------
# 10. systemd units + Caddyfile
# -----------------------------------------------------------------------------
install_units() {
	log "10/12 Cài systemd units + Caddyfile"
	local protect="yes"
	if [[ "$GTINX_DIR" == /root/* || "$GTINX_DIR" == /home/* ]]; then
		protect="no" # systemd sẽ che /root,/home nếu ProtectHome=yes
	fi
	GTINX_DIR="$GTINX_DIR" GTINX_USER="$GTINX_USER" GTINX_PROTECT_HOME="$protect" \
		bash "$GTINX_DIR/deployments/systemd/install.sh"

	# MinIO trên cùng máy => mở route /uploads trong proxy Caddyfile
	if [[ "$WITH_MINIO" == "1" ]]; then
		sed -i -E 's|^([[:space:]]*)#[[:space:]]+(reverse_proxy /\{\$BUCKET_NAME.*)$|\1\2|' \
			"$ENV_DIR/caddy/proxy.Caddyfile"
	fi
	systemctl daemon-reload
}

# -----------------------------------------------------------------------------
# 10b. Cổng 80: nginx/apache2/httpd/caddy mặc định có thể đang chiếm
# -----------------------------------------------------------------------------
resolve_port_conflicts() {
	log "10b/12 Kiểm tra cổng 80"
	local conflicts=() u listening=0

	for u in caddy nginx apache2 httpd lighttpd; do
		if systemctl is-active --quiet "$u.service" 2>/dev/null; then
			conflicts+=("$u")
		fi
	done

	if ss -lntH 'sport = :80' 2>/dev/null | grep -q .; then
		listening=1
	fi

	if [[ ${#conflicts[@]} -eq 0 ]]; then
		if [[ $listening -eq 1 ]] && ! systemctl is-active --quiet gtinx-plane-proxy.service 2>/dev/null; then
			warn "Cổng 80 đã bị process khác chiếm:"
			ss -lntpH 'sport = :80' 2>/dev/null | sed 's/^/    /'
			warn "  gtinx-plane-proxy sẽ không bind được :80 -> web không truy cập được."
		else
			ok "Cổng 80 sẵn sàng cho gtinx-plane-proxy"
		fi
		return 0
	fi

	if [[ "$DISABLE_CONFLICTING_SERVICES" == "1" ]]; then
		for u in "${conflicts[@]}"; do
			systemctl disable --now "$u.service" >/dev/null 2>&1 || true
			ok "Đã tắt $u.service (giải phóng cổng 80 cho gtinx-plane-proxy)"
		done
	else
		warn "Cổng 80 đang bị chiếm bởi: ${conflicts[*]}"
		warn "  gtinx-plane-proxy sẽ KHÔNG bind được :80 -> trình duyệt thấy trang mặc định của ${conflicts[0]}."
		warn "  Tắt: sudo systemctl disable --now $(printf '%s.service ' "${conflicts[@]}")"
		warn "  Hoặc chạy lại script với DISABLE_CONFLICTING_SERVICES=1"
		warn "  (nếu cần giữ ${conflicts[0]} cho site khác: cấu hình reverse proxy trong ${conflicts[0]}, đừng tắt)"
	fi
}

# -----------------------------------------------------------------------------
# 11. Khởi động
# -----------------------------------------------------------------------------
start_services() {
	log "11/12 Khởi động services"
	systemctl enable gtinx-plane-migrate.service >/dev/null
	systemctl restart gtinx-plane-migrate.service
	for svc in "${SERVICES[@]:1}"; do
		systemctl enable "$svc.service" >/dev/null
		systemctl restart "$svc.service"
	done
	ok "Đã start ${#SERVICES[@]} services"
}

# -----------------------------------------------------------------------------
# 12. Kiểm tra
# -----------------------------------------------------------------------------
wait_url() { # url, tên
	local url=$1 name=$2 i
	for i in $(seq 1 80); do
		if curl -fsS -o /dev/null "$url" 2>/dev/null; then
			ok "$name: $url"
			return 0
		fi
		sleep 3
	done
	warn "$name chưa sẵn sàng: $url"
	return 1
}

verify() {
	log "12/12 Kiểm tra"
	local failed=0
	wait_url "http://127.0.0.1:8000/api/instances/" "api" || failed=1
	wait_url "http://127.0.0.1:3200/" "web" || failed=1
	wait_url "http://127.0.0.1:3201/god-mode/" "admin" || failed=1
	wait_url "http://127.0.0.1:3202/spaces/" "space" || failed=1
	if [[ "$SITE_ADDRESS" == :* ]]; then
		if curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1${SITE_ADDRESS}/" 2>/dev/null; then
			ok "proxy: http://127.0.0.1${SITE_ADDRESS}/"
		else
			warn "proxy không phản hồi trên http://127.0.0.1${SITE_ADDRESS}/ (xem mục 10b: cổng 80 bị chiếm?)"
			failed=1
		fi
	fi
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
		ufw allow 80/tcp >/dev/null 2>&1 || true
		ufw allow 443/tcp >/dev/null 2>&1 || true
		ok "ufw: đã mở 80/443"
	fi
	if [[ $failed -ne 0 ]]; then
		warn "Một số service chưa lên. Xem log:"
		warn "  journalctl -u gtinx-plane-api -n 100 --no-pager"
		warn "  journalctl -u gtinx-plane-migrate -n 100 --no-pager"
	fi
}

# -----------------------------------------------------------------------------
# Tổng kết
# -----------------------------------------------------------------------------
summary() {
	cat <<EOF

$(printf '\033[1;32m')=============================================================
  gtinx-plane UAT đã deploy
=============================================================$(printf '\033[0m')

  URL       : $APP_URL
  Admin     : $APP_URL/god-mode/
  Code      : $GTINX_DIR
  Cấu hình  : $ENV_DIR/{api,live,proxy}.env
  Secret    : $SECRETS_FILE  (backup!)

  Lệnh hữu ích:
    systemctl status gtinx-plane-api
    journalctl -u gtinx-plane-api -f
    journalctl -u gtinx-plane-proxy -n 200 --no-pager
    systemctl restart gtinx-plane-api gtinx-plane-worker gtinx-plane-beat

  Bước tiếp theo: mở $APP_URL/god-mode/ để tạo instance + tài khoản admin.
EOF
}

install_packages
create_user
load_secrets
sync_code
write_envs
setup_minio
setup_datastores
setup_python
build_frontends
install_units
resolve_port_conflicts
start_services
verify
summary
