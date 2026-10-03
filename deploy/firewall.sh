#!/usr/bin/env bash
# Lock the VPS down to only what needs to be public: SSH, HTTP (for Let's
# Encrypt's challenge + redirect to HTTPS), and HTTPS. QLever (7878), QLever
# UI (7876) and the viewer (5000) are deliberately NOT opened here -- Caddy
# reaches them over localhost, nothing external should ever touch those
# ports directly.
#
# PUBLIC_IFACE is the NIC that carries the VPS's public IP -- `ip route show
# default` to find it if this box's isn't ens3.
set -euo pipefail

PUBLIC_IFACE="ens3"

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

# The three lines above are NOT sufficient on their own for Docker-published
# ports: Docker inserts its own iptables rules for every `-p host:container`
# mapping, and those rules sit in a chain (DOCKER-USER, reached via FORWARD)
# that ufw's INPUT-chain "default deny incoming" never touches. Without this
# block, `qlever start`/`qlever ui`'s containers -- which publish on all
# interfaces, not just localhost, since the `qlever` CLI has no flag for
# this -- are reachable from the public internet regardless of ufw's status
# output claiming otherwise. Confirmed this the hard way: ufw reported these
# ports closed while curl from an outside host connected to them directly.
#
# DOCKER-USER is a chain Docker guarantees it will never overwrite, which is
# why this is the correct (and standard, Docker-docs-recommended) insertion
# point, rather than fighting Docker's own rules in INPUT/FORWARD directly.
# Matching on `-i $PUBLIC_IFACE` specifically (not a bare DROP) is what
# keeps Caddy's own loopback connections to these same ports working --
# loopback traffic never arrives via the public NIC, so it never matches.
#
# Subtlety that cost real debugging time: DNAT (PREROUTING, nat table) runs
# BEFORE this chain (FORWARD, filter table), so by the time a packet reaches
# DOCKER-USER its destination port has *already* been rewritten to the
# container's internal port -- not the host-published port -- whenever the
# two differ. QLever's main API publishes 7878:7878 (same port both sides,
# so matching 7878 happens to work), but QLever UI publishes 7876:7000
# (`qlever ui`'s `--publish 7876:7000`) -- a rule matching `--dport 7876`
# silently never fires for it. Match the *container-side* port instead.
if ! grep -q "DOCKER-USER" /etc/ufw/after.rules 2>/dev/null; then
  tee -a /etc/ufw/after.rules > /dev/null <<EOF

# --- block public access to Docker-published ports that must stay
# localhost-only (added by deploy/firewall.sh) ---
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i ${PUBLIC_IFACE} -p tcp --dport 7878 -j DROP
-A DOCKER-USER -i ${PUBLIC_IFACE} -p tcp --dport 7000 -j DROP
-A DOCKER-USER -j RETURN
COMMIT
EOF
  ufw reload
fi

ufw status verbose
