#!/usr/bin/env bash
# Logs here are written by root on purpose, not by the sudo-ed user.
# shellcheck disable=SC2024
# Runs INSIDE the test container (see tests/run.sh), as root.
# Each scenario runs the real roles and then checks the real system state.

set -uo pipefail
cd /home/demo/repo || exit 1

PASS=0
FAIL=0
FAILED=()

section() { printf '\n=== %s\n' "$1"; }
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$desc"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$desc"; FAIL=$((FAIL + 1)); FAILED+=("$desc")
  fi
}
# Same as check, for "this must NOT succeed".
check_not() { local desc="$1"; shift; check "$desc" bash -c '! "$@"' _ "$@"; }

LOG=/tmp/play.log
# play EXTRA_JSON [playbook] -> runs it as `sudo` from the demo user would
play() {
  local extra="${1:-{\}}" book="${2:-tests/play.yml}"
  SUDO_USER=demo ANSIBLE_ROLES_PATH=/home/demo/repo/roles ANSIBLE_NOCOLOR=1 \
    ansible-playbook "$book" -e @tests/overrides.yml -e "$extra" >"$LOG" 2>&1
}
show_log_on_fail() { [[ $1 -eq 0 ]] || { echo "  --- last lines of the play:"; tail -n 25 "$LOG" | sed 's/^/  | /'; }; }

sshd_opt() { /usr/sbin/sshd -T 2>/dev/null | awk -v k="$1" '$1 == k {print $2}'; }

# --- bootstrap: Ansible install ------------------------------------------------
section "bootstrap.sh installs a recent enough Ansible"
sudo -u demo -H env UBUNTU_SETUP_STOP_AFTER=ansible \
  ./bootstrap/bootstrap.sh --no-prompt >/tmp/bootstrap.log 2>&1
rc=$?
check "bootstrap.sh up to the Ansible step exits 0" test "$rc" -eq 0
[[ $rc -eq 0 ]] || tail -n 20 /tmp/bootstrap.log | sed 's/^/  | /'
core="$(ansible --version 2>/dev/null | sed -n 's/.*core \([0-9.]*\).*/\1/p' | head -n1)"
echo "  ansible-core: ${core:-none}"
check "ansible-core >= 2.16" bash -c "printf '%s\n%s\n' 2.16 '$core' | sort -V -C"
check "pinned community.general is in ./collections" \
  test -d collections/ansible_collections/community/general

# --- 1: defaults ----------------------------------------------------------------
section "1. Defaults (workstation): open to anyone, firewall on"
play; rc=$?; show_log_on_fail $rc
check "play succeeds" test $rc -eq 0
check "ufw is active" bash -c "ufw status | grep -q 'Status: active'"
check "SSH allowed from anywhere" bash -c "ufw status | grep -Eq '^22/tcp +ALLOW +Anywhere'"
check "RDP allowed from anywhere" bash -c "ufw status | grep -Eq '^3389/tcp +ALLOW +Anywhere'"
check "no SSH login policy file" test ! -e /etc/ssh/sshd_config.d/00-ubuntu-setup.conf
check "automatic updates on" grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades
check "no automatic reboot" grep -q 'Automatic-Reboot "false"' /etc/apt/apt.conf.d/52ubuntu-setup-unattended
check "fail2ban not set up" test ! -e /etc/fail2ban/jail.d/ubuntu-setup.local
check "journald stopped (logging off)" bash -c "! systemctl is-active -q systemd-journald"

# --- 2: key-only without a key ------------------------------------------------
section "2. Key-only SSH without an authorized key is refused"
rm -rf /home/demo/.ssh
play '{"ssh_key_only": true}'; rc=$?
check "play fails" test $rc -ne 0
check "message explains the lockout" grep -q "would lock you out" "$LOG"
check "password login still on" test "$(sshd_opt passwordauthentication)" = "yes"

# --- 3: server profile, restricted --------------------------------------------
section "3. Server profile: one IP, key-only, no root, fail2ban"
install -d -o demo -g demo -m 700 /home/demo/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOnlyATestKeyForTheContainer00000000000 demo@test" \
  | install -o demo -g demo -m 600 /dev/stdin /home/demo/.ssh/authorized_keys
play '{"setup_profile":"server","access_allowed_from":["203.0.113.7"],"ssh_key_only":true,"ssh_disable_root_login":true}'
rc=$?; show_log_on_fail $rc
check "play succeeds" test $rc -eq 0
check "SSH only from 203.0.113.7" bash -c "ufw status | grep -Eq '^22/tcp +ALLOW +203\.0\.113\.7 '"
check "RDP only from 203.0.113.7" bash -c "ufw status | grep -Eq '^3389/tcp +ALLOW +203\.0\.113\.7 '"
check_not "no allow-from-anywhere left" bash -c "ufw status | grep -Eq '^(22|3389)/tcp .*Anywhere'"
check "sshd: password login off" test "$(sshd_opt passwordauthentication)" = "no"
check "sshd: keyboard-interactive off" test "$(sshd_opt kbdinteractiveauthentication)" = "no"
check "sshd: root login off" test "$(sshd_opt permitrootlogin)" = "no"
check "sshd config is valid" /usr/sbin/sshd -t
check "journald running (logging on)" systemctl is-active -q systemd-journald
check "fail2ban running" systemctl is-active -q fail2ban
check "fail2ban sshd jail active" bash -c "fail2ban-client status | grep -q sshd"
check "fail2ban xrdp jail active" bash -c "fail2ban-client status | grep -q ubuntu-setup-xrdp"
check "allowed IP is never banned" bash -c "fail2ban-client get sshd ignoreip | grep -q 203.0.113.7"
# A failed xrdp login, in xrdp-sesman's log format.
check "xrdp filter matches a failed RDP login" bash -c \
  "fail2ban-regex '[20251123-11:59:02] [INFO ] AUTHFAIL: user=bob ip=::ffff:198.51.100.23 port=51234 time=1700000000' \
   /etc/fail2ban/filter.d/ubuntu-setup-xrdp.conf | grep -q '1 matched'"

# verify.sh reads the same answers from local.yml as bootstrap would leave.
printf 'access_allowed_from:\n  - "203.0.113.7"\nsetup_profile: server\nssh_key_only: true\nssh_disable_root_login: true\n' >local.yml
sudo -u demo -H ./verify.sh >/tmp/verify.log 2>&1
for line in "SSH only from allowed IPs" "RDP only from allowed IPs" "password login off" \
            "root login blocked" "logging on" "automatic security updates" "fail2ban running" \
            "jail sshd" "jail ubuntu-setup-xrdp"; do
  check "verify.sh: $line" grep -q "✔ $line" /tmp/verify.log
done
rm -f local.yml

# --- 4: switch to a range -----------------------------------------------------
section "4. Switching to a range removes the old IP"
play '{"setup_profile":"server","access_allowed_from":["198.51.100.0/24"],"ssh_key_only":true,"ssh_disable_root_login":true}'
rc=$?; show_log_on_fail $rc
check "play succeeds" test $rc -eq 0
check "SSH from the range" bash -c "ufw status | grep -Eq '^22/tcp +ALLOW +198\.51\.100\.0/24'"
check_not "old IP 203.0.113.7 gone" bash -c "ufw status | grep -q 203.0.113.7"

# --- 5: analysis-vm -----------------------------------------------------------
section "5. Analysis-VM profile: logging on, no fail2ban, no auto-updates"
play '{"setup_profile":"analysis-vm"}'; rc=$?; show_log_on_fail $rc
check "play succeeds" test $rc -eq 0
check "automatic updates off" grep -q 'Unattended-Upgrade "0"' /etc/apt/apt.conf.d/20auto-upgrades
check "fail2ban stopped" bash -c "! systemctl is-active -q fail2ban"
check "fail2ban jails removed" test ! -e /etc/fail2ban/jail.d/ubuntu-setup.local
check "journald running" systemctl is-active -q systemd-journald
check "password login back on" test "$(sshd_opt passwordauthentication)" = "yes"
check "open to anyone again" bash -c "ufw status | grep -Eq '^22/tcp +ALLOW +Anywhere'"
check_not "range rule cleaned up" bash -c "ufw status | grep -q 198.51.100.0/24"

# --- 6: invalid combinations --------------------------------------------------
section "6. Preflight refuses dangerous or invalid settings"
play '{"fail2ban_enabled": true, "hardening_disable_logging": true}'; rc=$?
check "fail2ban + logging off refused" bash -c "[ $rc -ne 0 ] && grep -q 'works by reading the logs' $LOG"
play '{"access_allowed_from": ["203.0.113"]}'; rc=$?
check "malformed IP refused" bash -c "[ $rc -ne 0 ] && grep -q 'is not an IP address' $LOG"
play '{"setup_profile": "laptop"}'; rc=$?
check "unknown profile refused" bash -c "[ $rc -ne 0 ] && grep -q 'use workstation, server or' $LOG"
play '{"xrdp_tls_cert": "/nope/cert.pem", "xrdp_tls_key": "/nope/key.pem"}'; rc=$?
check "missing RDP certificate refused" bash -c "[ $rc -ne 0 ] && grep -q 'Not found' $LOG"

# --- 7: hardening alone, no SSH rule ------------------------------------------
section "7. Hardening alone will not lock SSH out"
ufw --force reset >/dev/null
ufw allow 3389/tcp >/dev/null
play '{}' tests/play-hardening.yml; rc=$?
check "play fails" test $rc -ne 0
check "message names the lockout" grep -q "Not enabling ufw" "$LOG"
check "ufw left inactive" bash -c "ufw status | grep -q 'Status: inactive'"

# --- 8: bootstrap questions ---------------------------------------------------
section "8. bootstrap.sh questions"
# ask SSH_CONNECTION INPUT [ARGS] -> runs the questions in a real terminal
ask() {
  sudo -u demo -H bash -c "cd /home/demo/repo && export SSH_CONNECTION='$1' UBUNTU_SETUP_STOP_AFTER=questions \
    && printf '$2' | script -qec './bootstrap/bootstrap.sh ${3:-}' /dev/null" >/tmp/ask.log 2>&1
}
rm -f local.yml
# server profile, default IP, key-only after confirming, block root
ask "203.0.113.7 51000 10.0.0.2 22" '2\n\ny\ny\n\n'
check "saves the server profile" grep -qx 'setup_profile: server' local.yml
check "defaults to the current SSH client IP" grep -qx '  - "203.0.113.7"' local.yml
check "key-only after confirmation" grep -qx 'ssh_key_only: true' local.yml
check "root login blocked by default" grep -qx 'ssh_disable_root_login: true' local.yml
check "local.yml is private (600)" test "$(stat -c %a local.yml)" = 600

ask "198.51.100.5 51000 10.0.0.2 22" 'n\nn\n'
check "warns when the saved list shuts out your IP" grep -q "NOT in that list" /tmp/ask.log
check "stops when you decline" bash -c "! grep -q 'Stopping after the questions' /tmp/ask.log"

ask "198.51.100.5 51000 10.0.0.2 22" '\n2\nabc\n203.0.113.0/24\n\nn\n3\nn\nn\n' --reconfigure
check "rejects input that is not an IP" grep -q '"abc" is not an IP address' /tmp/ask.log
check "warns about locking yourself out" grep -q "NOT in that list" /tmp/ask.log
check "anywhere -> empty list" grep -qx 'access_allowed_from: \[\]' local.yml

rm -f local.yml
sudo -u demo -H bash -c "cd /home/demo/repo && UBUNTU_SETUP_STOP_AFTER=questions ./bootstrap/bootstrap.sh --no-prompt" >/tmp/ask.log 2>&1
check "--no-prompt uses the defaults" grep -q "using group_vars defaults" /tmp/ask.log
check "--no-prompt writes nothing" test ! -e local.yml

# --- summary ------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
