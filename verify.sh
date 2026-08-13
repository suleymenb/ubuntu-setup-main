#!/usr/bin/env bash
# verify.sh — post-run health check for the ubuntu-setup playbook.
# Exit code 0 = everything passed, 1 = at least one FAIL.

set -uo pipefail

# Package lists come from group_vars/all.yml — the same file the playbook
# installs from — so this script can never drift out of sync with it.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="$REPO_ROOT/group_vars/all.yml"

read_list() {
  python3 - "$VARS_FILE" "$1" <<'PY'
import sys, yaml
try:
    data = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
value = data.get(sys.argv[2], [])
if not isinstance(value, list):
    value = [value]
for entry in value or []:
    print(entry)
PY
}

if [[ ! -f "$VARS_FILE" ]] || ! python3 -c "import yaml" 2>/dev/null; then
  printf "Warning: cannot read %s — falling back to built-in lists.\n" "$VARS_FILE"
  USE_VARS=0
else
  USE_VARS=1
fi

list_or() {
  local out=""
  (( USE_VARS )) && out="$(read_list "$1")"
  [[ -z "$out" ]] && out="$2"
  printf '%s\n' "$out"
}

PASS=0
FAIL=0
WARN=0
FAILED_ITEMS=()

if [[ -t 1 ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi

section() { printf "\n%s— %s —%s\n" "$B" "$1" "$N"; }
ok()   { printf "  %s✔%s %-32s %s\n" "$G" "$N" "$1" "${2:-}"; PASS=$((PASS+1)); }
bad()  { printf "  %s✘%s %-32s %s\n" "$R" "$N" "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED_ITEMS+=("$1"); }
warn() { printf "  %s!%s %-32s %s\n" "$Y" "$N" "$1" "${2:-}"; WARN=$((WARN+1)); }

check_pkg() {
  if dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; then
    ok "$1" "$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null)"
  else
    bad "$1" "not installed"
  fi
}

printf "%subuntu-setup verification%s  —  %s\n" "$B" "$N" "$(date '+%Y-%m-%d %H:%M')"

# --- system ------------------------------------------------------------------
section "System"

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  ok "Distribution" "$PRETTY_NAME"
else
  bad "Distribution" "/etc/os-release missing"
fi

target=$(systemctl get-default 2>/dev/null)
if [[ "$target" == "graphical.target" ]]; then
  ok "Default systemd target" "$target"
else
  bad "Default systemd target" "$target (expected graphical.target)"
fi

# --- desktop -----------------------------------------------------------------
section "Desktop"

for p in $(list_or desktop_packages "lxde"); do
  check_pkg "$p"
done

if command -v startlxde >/dev/null 2>&1; then
  ok "startlxde on PATH"
else
  warn "startlxde on PATH" "LXDE may not be fully installed"
fi

# --- apps --------------------------------------------------------------------
section "Apps"

for p in $(list_or apps_packages "vlc veracrypt"); do
  check_pkg "$p"
done

# snaps, read from the same group_vars list
if (( USE_VARS )); then
  while IFS= read -r sname; do
    [[ -z "$sname" ]] && continue
    if snap list "$sname" >/dev/null 2>&1; then
      ok "snap $sname" "$(snap list "$sname" 2>/dev/null | awk 'NR==2{print $2}')"
    else
      bad "snap $sname" "not installed"
    fi
  done < <(python3 - "$VARS_FILE" <<'PY' 2>/dev/null
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
for s in data.get('apps_snaps') or []:
    print(s.get('name',''))
PY
)
fi

# --- jetbrains ---------------------------------------------------------------
section "JetBrains"

if (( USE_VARS )); then
  while IFS= read -r ide; do
    [[ -z "$ide" ]] && continue
    check_pkg "$ide"
  done < <(read_list jetbrains_ides)
fi

# --- shell -------------------------------------------------------------------
section "Shell"

login_user="${SUDO_USER:-$USER}"
if [[ -d "/home/${login_user}/.oh-my-zsh" ]]; then
  ok "Oh My Zsh installed"
else
  bad "Oh My Zsh installed" "for $login_user"
fi
if getent passwd "$login_user" | grep -q '/zsh$'; then
  ok "default shell is zsh"
else
  warn "default shell is zsh" "$(getent passwd "$login_user" | cut -d: -f7)"
fi

# --- hardening ---------------------------------------------------------------
section "Hardening"

if systemctl is-enabled sleep.target 2>/dev/null | grep -q masked; then
  ok "sleep masked"
else
  warn "sleep masked" "still enabled"
fi
if systemctl is-active systemd-journald >/dev/null 2>&1; then
  warn "journald disabled" "still running"
else
  ok "journald disabled"
fi
if sudo -n ufw status 2>/dev/null | grep -q "Status: active"; then
  ok "ufw active"
else
  warn "ufw active" "not enabled"
fi

# --- virtualisation ----------------------------------------------------------
section "Virtualisation"

for p in $(list_or virt_packages "qemu-system-x86 libvirt-daemon-system virt-manager"); do
  check_pkg "$p"
done

# Packages alone are not enough — group membership decides whether it works.
login_user="${SUDO_USER:-$USER}"
for g in $(list_or virt_user_groups "libvirt kvm"); do
  if id -nG "$login_user" 2>/dev/null | grep -qw "$g"; then
    ok "$login_user in group $g"
  else
    bad "$login_user in group $g" "log out and back in after adding"
  fi
done

if [[ -e /dev/kvm ]]; then
  ok "/dev/kvm present" "hardware acceleration available"
else
  warn "/dev/kvm present" "no nested virtualisation — QEMU will be slow"
fi

if systemctl is-active libvirtd >/dev/null 2>&1; then
  ok "libvirtd running"
else
  warn "libvirtd running" "systemctl start libvirtd"
fi

# GitHub-release .debs, read from the same group_vars list
if (( USE_VARS )); then
  while IFS='|' read -r dname darch; do
    [[ -z "$dname" ]] && continue
    if [[ "$(dpkg --print-architecture)" != "$darch" ]]; then
      warn "$dname" "skipped — no .deb for $(dpkg --print-architecture)"
    else
      check_pkg "$dname"
    fi
  done < <(python3 - "$VARS_FILE" <<'PY' 2>/dev/null
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
for d in data.get('apps_github_debs') or []:
    print("%s|%s" % (d.get('name',''), (d.get('architectures') or ['amd64'])[0]))
PY
)
fi

# --- xrdp --------------------------------------------------------------------
section "xrdp"

for p in $(list_or xrdp_packages "xrdp"); do
  check_pkg "$p"
done

if systemctl is-enabled xrdp >/dev/null 2>&1; then
  ok "xrdp enabled at boot"
else
  bad "xrdp enabled at boot" "systemctl enable xrdp"
fi

if systemctl is-active xrdp >/dev/null 2>&1; then
  ok "xrdp running"
else
  bad "xrdp running" "systemctl start xrdp"
fi

xrdp_port=$(list_or xrdp_port "3389" | head -n1)
if ss -ltn 2>/dev/null | grep -q ":${xrdp_port}\b"; then
  ok "listening on ${xrdp_port}"
else
  bad "listening on ${xrdp_port}" "nothing bound — journalctl -u xrdp -n 50"
fi

if id -nG xrdp 2>/dev/null | grep -qw ssl-cert; then
  ok "xrdp in ssl-cert group"
else
  bad "xrdp in ssl-cert group" "TLS errors on connect — adduser xrdp ssl-cert"
fi

# ~/.xsession decides what starts after login. Missing it is the classic
# "I connect but only get a grey screen".
login_user="${SUDO_USER:-$USER}"
xsession="/home/${login_user}/.xsession"
if [[ -f "$xsession" ]]; then
  ok ".xsession for $login_user" "$(head -n1 "$xsession")"
else
  bad ".xsession for $login_user" "missing — RDP will show a grey screen"
fi

# --- firewall ----------------------------------------------------------------
section "Firewall"

if command -v ufw >/dev/null 2>&1; then
  if sudo -n ufw status 2>/dev/null | grep -q "Status: active"; then
    if sudo -n ufw status 2>/dev/null | grep -q "${xrdp_port}"; then
      ok "ufw allows ${xrdp_port}"
    else
      bad "ufw allows ${xrdp_port}" "ufw allow ${xrdp_port}/tcp"
    fi
  else
    ok "ufw inactive" "no rule needed"
  fi
else
  ok "ufw not installed" "no rule needed"
fi

# --- summary -----------------------------------------------------------------
printf "\n%s────────────────────────────────────────%s\n" "$B" "$N"
printf "  %spassed: %d%s   %swarnings: %d%s   %sfailed: %d%s\n" \
  "$G" "$PASS" "$N" "$Y" "$WARN" "$N" "$R" "$FAIL" "$N"

if (( FAIL > 0 )); then
  printf "\n%sFailed checks:%s\n" "$R" "$N"
  for item in "${FAILED_ITEMS[@]}"; do
    printf "  - %s\n" "$item"
  done
  printf "\nRe-run the playbook, or a single role:\n"
  printf "  ansible-playbook playbook.yml --tags xrdp\n"
  exit 1
fi

printf "\n%sAll checks passed.%s\n" "$G" "$N"
exit 0
