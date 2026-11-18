#!/usr/bin/env bash
# Install gtinx-plane systemd units, Caddy configs and env templates on a Linux host.
# Run as root, from the repository root:  sudo bash ./deployments/systemd/install.sh
#
# Env overrides:
#   GTINX_DIR=/opt/gtinx-plane   GTINX_USER=gtinx
#   GTINX_PROTECT_HOME=yes   (set to "no" when the code lives under /home or /root)
#   SKIP_UNITS=1           only install env/caddy files
set -euo pipefail

GTINX_DIR=${GTINX_DIR:-/opt/gtinx-plane}
GTINX_USER=${GTINX_USER:-gtinx}
GTINX_PROTECT_HOME=${GTINX_PROTECT_HOME:-yes}

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
	echo "Run as root (sudo)." >&2
	exit 1
fi

echo "==> gtinx-plane dir:  $GTINX_DIR"
echo "==> gtinx-plane user: $GTINX_USER"
echo "==> ProtectHome:      $GTINX_PROTECT_HOME"

case "$GTINX_PROTECT_HOME" in
	yes | no) ;;
	*)
		echo "GTINX_PROTECT_HOME must be 'yes' or 'no'." >&2
		exit 1
		;;
esac

if [[ "$GTINX_PROTECT_HOME" == "no" && "$GTINX_DIR" != /root/* && "$GTINX_DIR" != /home/* ]]; then
	echo "==> Warning: ProtectHome=no requested but $GTINX_DIR is not under /root or /home"
fi

# 1. Service user
if ! id -u "$GTINX_USER" >/dev/null 2>&1; then
	echo "==> Creating system user $GTINX_USER"
	useradd --system --home-dir "$GTINX_DIR" --shell /usr/sbin/nologin "$GTINX_USER"
else
	echo "==> User $GTINX_USER already exists"
fi

# 2. Directories
echo "==> Creating /etc/gtinx-plane, /etc/gtinx-plane/caddy, /var/lib/gtinx-plane/caddy"
install -d -m 0750 -o root -g "$GTINX_USER" /etc/gtinx-plane
install -d -m 0750 -o root -g "$GTINX_USER" /etc/gtinx-plane/caddy
install -d -m 0750 -o "$GTINX_USER" -g "$GTINX_USER" /var/lib/gtinx-plane/caddy

# 3. Env files (never overwrite existing secrets)
for f in api live proxy; do
	target="/etc/gtinx-plane/$f.env"
	if [[ -f "$target" ]]; then
		echo "==> Keeping existing $target"
	else
		echo "==> Installing $target"
		install -m 0640 -o root -g "$GTINX_USER" "$SRC_DIR/env/$f.env.example" "$target"
	fi
done

# 4. Caddy configs
for f in web admin proxy; do
	echo "==> Installing /etc/gtinx-plane/caddy/$f.Caddyfile"
	sed "s|/opt/gtinx-plane|$GTINX_DIR|g" "$SRC_DIR/caddy/$f.Caddyfile" \
		> "/etc/gtinx-plane/caddy/$f.Caddyfile"
	chmod 0644 "/etc/gtinx-plane/caddy/$f.Caddyfile"
done

# 5. systemd units
if [[ ${SKIP_UNITS:-0} != "1" ]]; then
	for unit in "$SRC_DIR"/units/*.service; do
		name="$(basename "$unit")"
		echo "==> Installing /etc/systemd/system/$name"
		sed -e "s|/opt/gtinx-plane|$GTINX_DIR|g" \
			-e "s|^User=gtinx$|User=$GTINX_USER|" \
			-e "s|^Group=gtinx$|Group=$GTINX_USER|" \
			-e "s|^ProtectHome=yes$|ProtectHome=$GTINX_PROTECT_HOME|" \
			"$unit" >"/etc/systemd/system/$name"
		chmod 0644 "/etc/systemd/system/$name"
	done
	systemctl daemon-reload
fi

echo
echo "Next steps:"
echo "  1. Edit secrets in /etc/gtinx-plane/api.env and /etc/gtinx-plane/live.env"
echo "     (SECRET_KEY, LIVE_SERVER_SECRET_KEY, DATABASE_URL, REDIS_URL, RABBITMQ_*, AWS_*)"
echo "  2. Set SITE_ADDRESS in /etc/gtinx-plane/proxy.env"
echo "  3. Make sure the code is in $GTINX_DIR and built (see README.md)"
echo "  4. chown -R $GTINX_USER:$GTINX_USER $GTINX_DIR"
echo "  5. systemctl enable --now gtinx-plane-migrate.service gtinx-plane-api.service \\"
echo "       gtinx-plane-worker.service gtinx-plane-beat.service gtinx-plane-live.service \\"
echo "       gtinx-plane-space.service gtinx-plane-web.service gtinx-plane-admin.service gtinx-plane-proxy.service"
echo
