#!/usr/bin/env bash
#
# secure-ubuntu-2026.sh
# Idempotent Ubuntu/Debian security hardening + auto-start services
# Safe to re-run; now forces start of fail2ban + diagnostics

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Starting security setup (idempotent + auto-start 2026 edition)${NC}\n"

# ────────────────────────────────────────────────
# Install if missing
# ────────────────────────────────────────────────
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -yqq --no-install-recommends \
    ufw fail2ban openssh-server

# ────────────────────────────────────────────────
# UFW (same as before, idempotent)
# ────────────────────────────────────────────────
if ! ufw status | grep -qE "(OpenSSH|22/tcp)"; then
    ufw allow OpenSSH 2>/dev/null || ufw allow 22/tcp
    echo "  → SSH allowed in UFW"
fi

ufw default deny incoming   || true
ufw default allow outgoing  || true

if ! ufw status | grep -q "Status: active"; then
    echo "y" | ufw enable
    echo "  → UFW enabled"
else
    ufw reload
fi

echo -e "${GREEN}UFW ready:${NC}"
ufw status | head -n 8

# ────────────────────────────────────────────────
# SSH hardening (drop-in preferred)
# ────────────────────────────────────────────────
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-security.conf"

if [[ -d "/etc/ssh/sshd_config.d" && ( ! -f "$SSHD_DROPIN" || ! grep -q "PasswordAuthentication no" "$SSHD_DROPIN" ) ]]; then
    cat > "$SSHD_DROPIN" << 'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
    systemctl restart ssh || systemctl restart sshd
    echo "  → SSH hardened (drop-in)"
fi

# ────────────────────────────────────────────────
# Fail2Ban – use jail.d drop-in + force start
# ────────────────────────────────────────────────
echo -e "${GREEN}Configuring Fail2Ban...${NC}"

mkdir -p /etc/fail2ban/jail.d

# Clean drop-in without inline comment mess
cat > /etc/fail2ban/jail.d/sshd-aggressive.conf << 'EOF'
[sshd]
enabled   = true
port      = ssh
filter    = sshd
backend   = systemd      # Use systemd journal (preferred on Ubuntu 22.04+)
mode      = aggressive
maxretry  = 3
findtime  = 10m
bantime   = 24h
EOF

# Optional: global fallback if no jail-specific backend works
if [[ ! -f /etc/fail2ban/jail.local ]] || ! grep -q "backend" /etc/fail2ban/jail.local; then
    echo -e "[DEFAULT]\nbackend = auto" >> /etc/fail2ban/jail.local 2>/dev/null || true
fi

# Ensure python3-systemd (rarely missing, but covers minimal installs)
apt-get install -yqq python3-systemd || true

systemctl daemon-reload
systemctl enable fail2ban --quiet || true
systemctl restart fail2ban

sleep 4  # Give time for socket creation

# Quick validation
if [[ -S /var/run/fail2ban/fail2ban.sock ]]; then
    echo -e "${GREEN}Fail2Ban socket OK${NC}"
    fail2ban-client status sshd || echo "  (sshd jail query issue – check logs)"
else
    echo -e "${RED}Fail2Ban still not running – check journalctl -u fail2ban -xe${NC}"
fi

echo ""
echo "Recent fail2ban logs:"
tail -n 20 /var/log/fail2ban.log 2>/dev/null || echo "No log entries yet"

sleep 3  # give it a moment to create socket

# ────────────────────────────────────────────────
# Diagnostics – very important for fail2ban issues
# ────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Fail2Ban diagnostics:${NC}"

if [[ -S /var/run/fail2ban/fail2ban.sock ]]; then
    echo -e "${GREEN}OK: Socket exists → server is (probably) running${NC}"
    fail2ban-client status sshd 2>/dev/null || echo "  (but sshd jail query failed?)"
else
    echo -e "${RED}Socket MISSING → fail2ban-server not running${NC}"
fi

echo ""
echo "systemctl status fail2ban:"
systemctl status fail2ban --no-pager | head -n 12 || true

echo ""
echo "Last 20 lines of fail2ban.log:"
tail -n 20 /var/log/fail2ban.log 2>/dev/null || echo "  (log not found yet)"

echo ""
echo "Config test:"
fail2ban-client -t 2>/dev/null || echo "  (test failed – see log above)"

echo -e "\n${YELLOW}If fail2ban still fails:${NC}"
echo "1. Check journalctl -u fail2ban -n 60"
echo "2. Look for 'No log file' / 'Bad substitution' / 'asynchat' errors"
echo "3. Try: sudo fail2ban-client -x start   # force start with verbose"
echo ""

echo -e "${GREEN}Script finished. Review output above.${NC}"
