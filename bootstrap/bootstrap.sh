#!/usr/bin/env bash
# bootstrap.sh
# 1) Installs Ansible
# 2) Installs the required collections
# 3) Runs the playbook
# 4) Runs verify.sh

set -euo pipefail

log() { printf "\n==> %s\n" "$1"; }

# --- 0) Which checkout am I actually running? -------------------------------
# Running `git clone` from inside an existing clone nests the repo inside
# itself. You then edit one copy and run another, and nothing you change seems
# to take effect. Refuse to start rather than let that happen silently.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_NAME="$(basename "$REPO_ROOT")"
NEST_COUNT="$(tr '/' '\n' <<<"$REPO_ROOT" | grep -cx "$REPO_NAME" || true)"

if [[ "$NEST_COUNT" -gt 1 ]]; then
  cat >&2 <<EOF

==> ERROR: this checkout is nested inside another copy of itself.

    $REPO_ROOT

    "$REPO_NAME" appears $NEST_COUNT times in that path, which means you very
    likely ran "git clone" from inside an existing clone.

    Clean it up:
      rm -rf ~/$REPO_NAME
      cd ~ && git clone https://github.com/suleymenb/ubuntu-setup-main.git

    Always clone from your home directory — git creates the subfolder for you.

EOF
  exit 1
fi

log "Running from: $REPO_ROOT"
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  log "Commit:      $(git -C "$REPO_ROOT" log --oneline -1 2>/dev/null)"
fi

# --- 1) Sanity checks --------------------------------------------------------
if [[ ! -f /etc/debian_version ]]; then
  log "ERROR: this targets Ubuntu/Debian only."
  exit 1
fi

if [[ "$EUID" -eq 0 ]]; then
  log "ERROR: do not run this as root. Run it as your normal user; it uses sudo"
  log "       where needed, and the desktop session is configured for that user."
  exit 1
fi

# --- 2) Prime sudo -----------------------------------------------------------
log "Asking for your password once (needed for apt and systemctl)"
sudo -v
while true; do
  sudo -n true
  sleep 60
  kill -0 "$$" 2>/dev/null || exit
done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# --- 3) Ansible --------------------------------------------------------------
log "Checking Ansible"
if ! command -v ansible-playbook >/dev/null 2>&1; then
  log "Installing Ansible"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ansible
fi

log "Installing required Ansible collections"
ansible-galaxy collection install -r "$REPO_ROOT/requirements.yml"

# --- 4) Run playbook ---------------------------------------------------------
# Run ansible-playbook itself under sudo, deliberately.
#
# The alternatives all lose on this host:
#  - Plain ansible-playbook: Ubuntu's tty_tickets means Ansible's non-tty sudo
#    cannot use the credential cached above -> "interactive authentication
#    is required".
#  - ansible-playbook -K: some PAM stacks answer Ansible's custom prompt with a
#    second "Password:" prompt, which Ansible cannot answer -> "Timed out
#    waiting for become success".
#
# sudo here reuses the tty credential from step 2 (no prompt), the play's
# become is a no-op because we are already root, and sudo sets SUDO_USER so
# the xrdp role still knows which real user gets ~/.xsession.
cd "$REPO_ROOT"
log "Running Ansible playbook (as root via sudo)"
sudo ansible-playbook playbook.yml

# --- 5) Verify ---------------------------------------------------------------
if [[ -x "$REPO_ROOT/verify.sh" ]]; then
  log "Verifying installation"
  "$REPO_ROOT/verify.sh" || log "Some checks failed — see the list above"
fi

log "Setup complete"
