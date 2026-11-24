#!/usr/bin/env bash
# verify.sh — post-run health check for the ubuntu-setup playbook.
# Exit code 0 = everything passed, 1 = at least one FAIL.

set -uo pipefail

# Package lists come from group_vars/all.yml — the same file the playbook
# installs from — so this script can never drift out of sync with it.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="$REPO_ROOT/group_vars/all.yml"
# Your answers from bootstrap.sh, which override group_vars — same as the
# playbook sees them.
LOCAL_VARS="$REPO_ROOT/local.yml"

read_list() {
  python3 - "$VARS_FILE" "$LOCAL_VARS" "$1" <<'PY'
import os, sys, yaml
data = {}
for path in sys.argv[1:3]:
    if not os.path.exists(path):
        continue
    try:
        data.update(yaml.safe_load(open(path)) or {})
    except Exception:
        pass
value = data.get(sys.argv[3], [])
# Profile-driven settings are Jinja expressions such as
# "{{ setup_profile == 'server' }}". Render them against the same data the
# playbook sees, so this script agrees with what Ansible did.
if isinstance(value, str) and "{{" in value:
    try:
        import jinja2
        value = jinja2.Environment().from_string(value).render(**data).strip()
    except Exception:
        pass
if not isinstance(value, list):
    value = [value]
for entry in value or []:
    # YAML booleans come back as True/False; print them as the file spells them.
    text = str(entry)
    print(text.lower() if text in ("True", "False") else text)
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

# The real user (also when run under sudo) and their home directory, which is
# not always /home/<name>.
login_user="${SUDO_USER:-${USER:-$(id -un)}}"
login_home="$(getent passwd "$login_user" | cut -d: -f6)"
login_home="${login_home:-/home/$login_user}"

# A setting as the playbook sees it is "true" (profile expressions rendered).
is_true() { [[ "$(list_or "$1" "$2" | head -n1)" == "true" ]]; }

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
  # shellcheck source=/dev/null
  . /etc/os-release
  ok "Distribution" "$PRETTY_NAME"
else
  bad "Distribution" "/etc/os-release missing"
fi

target=$(systemctl get-default 2>/dev/null)
want_target=$(list_or desktop_systemd_target "graphical.target" | head -n1)
if [[ "$target" == "$want_target" ]]; then
  ok "Default systemd target" "$target"
else
  bad "Default systemd target" "$target (expected $want_target)"
fi

# --- desktop -----------------------------------------------------------------
section "Desktop"

for p in $(list_or desktop_packages "lxde"); do
  check_pkg "$p"
done

session_cmd=$(list_or xrdp_session_command "startlxde" | head -n1)
session_bin=${session_cmd%% *}
if command -v "$session_bin" >/dev/null 2>&1; then
  ok "$session_bin on PATH"
else
  warn "$session_bin on PATH" "the desktop may not be fully installed"
fi

# --- apps --------------------------------------------------------------------
section "Apps"

for p in $(list_or apps_packages "vlc veracrypt"); do
  check_pkg "$p"
done

for p in $(list_or apps_optional_packages ""); do
  if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
    ok "$p" "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)"
  else
    warn "$p" "optional — not available on this release"
  fi
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

if [[ -d "${login_home}/.oh-my-zsh" ]]; then
  ok "Oh My Zsh installed"
else
  bad "Oh My Zsh installed" "for $login_user"
fi
if ! is_true zsh_make_default_shell true; then
  :
elif getent passwd "$login_user" | grep -q '/zsh$'; then
  ok "default shell is zsh"
else
  warn "default shell is zsh" "$(getent passwd "$login_user" | cut -d: -f7)"
fi

# --- hardening ---------------------------------------------------------------
section "Hardening"

# Each check only runs when its toggle is on, so turning one off on purpose
# does not show up as a warning.
if is_true hardening_disable_sleep true; then
  if systemctl is-enabled sleep.target 2>/dev/null | grep -q masked; then
    ok "sleep masked"
  else
    warn "sleep masked" "still enabled"
  fi
fi
profile=$(list_or setup_profile "workstation" | head -n1)
# With logging off journald keeps running (it owns /dev/log) but stores
# nothing; what matters is Storage=none.
if is_true hardening_disable_logging true; then
  if grep -qx 'Storage=none' /etc/systemd/journald.conf 2>/dev/null; then
    ok "logging off" "journald stores nothing ($profile profile)"
  else
    warn "logging off" "Storage=none not set in journald.conf ($profile profile)"
  fi
  if ! systemctl is-active systemd-journald >/dev/null 2>&1; then
    bad "journald running" "sudo systemctl unmask --now systemd-journald"
  fi
else
  if systemctl is-active systemd-journald >/dev/null 2>&1; then
    ok "logging on" "$profile profile"
  else
    bad "logging on" "journald not running — re-run --tags hardening"
  fi
fi
if is_true hardening_firewall true; then
  if sudo -n ufw status 2>/dev/null | grep -q "Status: active"; then
    ok "ufw active"
  else
    warn "ufw active" "not enabled (or run with sudo to check)"
  fi
fi

# --- updates -----------------------------------------------------------------
section "Updates"

if [[ "$(list_or updates_enabled true | head -n1)" == "true" ]]; then
  check_pkg unattended-upgrades
  if grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
    ok "automatic security updates" "on"
  else
    bad "automatic security updates" "off — re-run --tags updates"
  fi
else
  ok "automatic security updates" "off ($profile profile)"
fi
if [[ -f /var/run/reboot-required ]]; then
  warn "reboot required" "an update is waiting for it — sudo reboot"
fi

# --- fail2ban ----------------------------------------------------------------
section "fail2ban"

if [[ "$(list_or fail2ban_enabled false | head -n1)" == "true" ]]; then
  if systemctl is-active fail2ban >/dev/null 2>&1; then
    ok "fail2ban running"
  else
    bad "fail2ban running" "systemctl status fail2ban"
  fi
  jails=$(sudo -n fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')
  if [[ -z "$jails" ]]; then
    warn "fail2ban jails" "run with sudo to check them"
  else
    for j in sshd ubuntu-setup-xrdp; do
      if grep -qw "$j" <<<"${jails//,/ }"; then ok "jail $j"; else bad "jail $j" "not active"; fi
    done
  fi
else
  ok "fail2ban" "off ($profile profile)"
fi

# --- virtualisation ----------------------------------------------------------
section "Virtualisation"

for p in $(list_or virt_packages "qemu-system-x86 libvirt-daemon-system virt-manager"); do
  check_pkg "$p"
done

# Packages alone are not enough — group membership decides whether it works.
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
      if [[ -x "/opt/$dname/$dname.AppImage" ]]; then
        ok "$dname" "AppImage $(cat "/opt/$dname/VERSION" 2>/dev/null)"
      else
        warn "$dname" "no .deb for $(dpkg --print-architecture), and no AppImage in /opt/$dname"
      fi
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
xsession="${login_home}/.xsession"
if [[ ! -f "$xsession" ]]; then
  bad ".xsession for $login_user" "missing — RDP will show a grey screen"
elif [[ "$(head -n1 "$xsession")" == "$session_cmd" ]]; then
  ok ".xsession for $login_user" "$session_cmd"
else
  bad ".xsession for $login_user" "says '$(head -n1 "$xsession")', expected '$session_cmd'"
fi

# --- firewall ----------------------------------------------------------------
section "Firewall"

ssh_port=$(list_or ssh_port "22" | head -n1)
allowed_from=$(list_or access_allowed_from "")

# ufw status needs root; without a cached sudo credential we say so instead of
# reporting a false failure.
ufw_status=""
if command -v ufw >/dev/null 2>&1; then
  ufw_status=$(sudo -n ufw status 2>/dev/null) || ufw_status="__nosudo__"
fi

# port_rules PORT -> the ufw status lines that allow PORT/tcp
port_rules() { grep -E "^${1}(/tcp)?[[:space:]]+ALLOW" <<<"$ufw_status"; }

if ! command -v ufw >/dev/null 2>&1; then
  ok "ufw not installed" "no rules needed"
elif [[ "$ufw_status" == "__nosudo__" ]]; then
  warn "ufw rules" "run with sudo to check them"
elif ! grep -q "Status: active" <<<"$ufw_status"; then
  ok "ufw inactive" "no rules needed"
else
  for pair in "SSH:$ssh_port" "RDP:$xrdp_port"; do
    name=${pair%%:*}; port=${pair#*:}
    rules=$(port_rules "$port")
    sources=$(awk '{print $3}' <<<"$rules" | sort -u | paste -sd, -)
    if [[ -z "$rules" ]]; then
      bad "ufw allows $name ($port)" "nothing allows it — sudo ansible-playbook playbook.yml --tags access"
    elif [[ -z "$allowed_from" ]]; then
      ok "ufw allows $name ($port)" "from $sources"
    elif grep -q "Anywhere" <<<"$rules"; then
      bad "$name only from allowed IPs" "still open to anywhere — re-run --tags access"
    else
      ok "$name only from allowed IPs" "$sources"
    fi
  done
fi

# --- ssh login ---------------------------------------------------------------
section "SSH login"

policy=/etc/ssh/sshd_config.d/00-ubuntu-setup.conf
if [[ "$(list_or ssh_key_only false | head -n1)" == "true" ]]; then
  if grep -qx "PasswordAuthentication no" "$policy" 2>/dev/null; then
    ok "password login off" "keys only"
  else
    bad "password login off" "$policy missing — re-run --tags access"
  fi
else
  ok "password login on" "set ssh_key_only to switch to keys"
fi
if [[ "$(list_or ssh_disable_root_login false | head -n1)" == "true" ]]; then
  if grep -qx "PermitRootLogin no" "$policy" 2>/dev/null; then
    ok "root login blocked"
  else
    bad "root login blocked" "$policy missing — re-run --tags access"
  fi
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
  printf "  sudo ansible-playbook playbook.yml --tags xrdp\n"
  exit 1
fi

printf "\n%sAll checks passed.%s\n" "$G" "$N"
exit 0
