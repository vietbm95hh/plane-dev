#!/usr/bin/env bash
# Install Plane systemd units, Caddy configs and env templates on a Linux host.
# Run as root, from the repository root:  sudo ./deployments/systemd/install.sh
#
# Env overrides:
#   PLANE_DIR=/opt/plane   PLANE_USER=plane
#   SKIP_UNITS=1           only install env/caddy files
set -euo pipefail

PLANE_DIR=${PLANE_DIR:-/opt/plane}
PLANE_USER=${PLANE_USER:-plane}

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
	echo "Run as root (sudo)." >&2
	exit 1
fi

echo "==> Plane dir:  $PLANE_DIR"
echo "==> Plane user: $PLANE_USER"

# 1. Service user
if ! id -u "$PLANE_USER" >/dev/null 2>&1; then
	echo "==> Creating system user $PLANE_USER"
	useradd --system --home-dir "$PLANE_DIR" --shell /usr/sbin/nologin "$PLANE_USER"
else
	echo "==> User $PLANE_USER already exists"
fi

# 2. Directories
echo "==> Creating /etc/plane, /etc/plane/caddy, /var/lib/plane/caddy"
install -d -m 0750 -o root -g "$PLANE_USER" /etc/plane
install -d -m 0750 -o root -g "$PLANE_USER" /etc/plane/caddy
install -d -m 0750 -o "$PLANE_USER" -g "$PLANE_USER" /var/lib/plane/caddy

# 3. Env files (never overwrite existing secrets)
for f in api live proxy; do
	target="/etc/plane/$f.env"
	if [[ -f "$target" ]]; then
		echo "==> Keeping existing $target"
	else
		echo "==> Installing $target"
		install -m 0640 -o root -g "$PLANE_USER" "$SRC_DIR/env/$f.env.example" "$target"
	fi
done

# 4. Caddy configs
for f in web admin proxy; do
	echo "==> Installing /etc/plane/caddy/$f.Caddyfile"
	sed "s|/opt/plane|$PLANE_DIR|g" "$SRC_DIR/caddy/$f.Caddyfile" \
		> "/etc/plane/caddy/$f.Caddyfile"
	chmod 0644 "/etc/plane/caddy/$f.Caddyfile"
done

# 5. systemd units
if [[ ${SKIP_UNITS:-0} != "1" ]]; then
	for unit in "$SRC_DIR"/units/*.service; do
		name="$(basename "$unit")"
		echo "==> Installing /etc/systemd/system/$name"
		sed "s|/opt/plane|$PLANE_DIR|g" "$unit" > "/etc/systemd/system/$name"
		chmod 0644 "/etc/systemd/system/$name"
	done
	systemctl daemon-reload
fi

echo
echo "Next steps:"
echo "  1. Edit secrets in /etc/gtinx_plane/api.env and /etc/plane/live.env"
echo "     (SECRET_KEY, LIVE_SERVER_SECRET_KEY, DATABASE_URL, REDIS_URL, RABBITMQ_*, AWS_*)"
echo "  2. Set SITE_ADDRESS in /etc/plane/proxy.env"
echo "  3. Make sure the code is in $PLANE_DIR and built (see README.md)"
echo "  4. chown -R $PLANE_USER:$PLANE_USER $PLANE_DIR"
echo "  5. systemctl enable --now plane-migrate.service plane-api.service \\"
echo "       plane-worker.service plane-beat.service plane-live.service \\"
echo "       plane-space.service plane-web.service plane-admin.service plane-proxy.service"
echo
