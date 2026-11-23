#!/usr/bin/env bash
# bootstrap.sh
# 1) Asks the machine profile, who may reach SSH/RDP and how SSH logs in
#    (saved to local.yml)
# 2) Installs Ansible
# 3) Installs the required collections
# 4) Runs the playbook
# 5) Runs verify.sh
#
# Options:
#   --reconfigure   ask the remote-access questions again
#   --no-prompt     never ask; use local.yml if present, else the defaults
#
# For tests: UBUNTU_SETUP_STOP_AFTER=questions|ansible stops after that step.

set -euo pipefail

RECONFIGURE=0
NO_PROMPT=0
for arg in "$@"; do
  case "$arg" in
    --reconfigure) RECONFIGURE=1 ;;
    --no-prompt)   NO_PROMPT=1 ;;
    -h|--help)     sed -n '2,14p' "$0"; exit 0 ;;
    *) printf "Unknown option: %s (try --help)\n" "$arg" >&2; exit 2 ;;
  esac
done

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

# --- 2) Remote access --------------------------------------------------------
# Asked BEFORE anything is installed: the firewall that ends up enabled has to
# let you back in. Answers go to local.yml (git-ignored), which the playbook
# loads on top of group_vars/all.yml, so a re-run does not ask again.
LOCAL_VARS="$REPO_ROOT/local.yml"
# $USER is not set in every context (e.g. docker exec, some su setups).
LOGIN_USER="${USER:-$(id -un)}"

# SSH_CONNECTION = "<client ip> <client port> <server ip> <server port>"
CLIENT_IP=""; SERVER_IP=""; SERVER_PORT=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  read -r CLIENT_IP _ SERVER_IP SERVER_PORT <<<"$SSH_CONNECTION"
fi

is_ip_or_cidr() {
  python3 -c 'import ipaddress, sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$1" 2>/dev/null
}

# ip_covered IP NET... -> true when IP falls inside one of the NETs
ip_covered() {
  python3 -c '
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(ip in ipaddress.ip_network(n, strict=False) for n in sys.argv[2:]) else 1)
' "$@" 2>/dev/null
}

# ask_yn "question" Y|N -> true for yes. Accepts y/j (ja) as yes.
ask_yn() {
  local reply hint="[y/N]"
  [[ "$2" == "Y" ]] && hint="[Y/n]"
  read -r -p "    $1 $hint " reply </dev/tty
  reply="${reply:-$2}"
  [[ "$reply" =~ ^[YyJj] ]]
}

# Reads access_allowed_from back from a local.yml this script wrote.
saved_sources() {
  sed -n 's/^  - "\(.*\)"$/\1/p' "$LOCAL_VARS"
}

# $@ = allowed sources. Returns 1 if the current SSH client would be cut off.
warn_if_locked_out() {
  [[ -z "$CLIENT_IP" || $# -eq 0 ]] && return 0
  ip_covered "$CLIENT_IP" "$@" && return 0
  cat <<EOF

    !! You are connected over SSH from $CLIENT_IP, which is NOT in that list.
    !! Once the firewall is on, a new SSH connection from here will be refused.
EOF
  return 1
}

configure_access() {
  local choice entry default_choice=2 key_only=false no_root=false profile
  local keys="$HOME/.ssh/authorized_keys"
  local -a sources=()

  log "What kind of machine is this?"
  cat <<EOF
    1) workstation   your own box: logging off, automatic security updates
    2) server        reachable from the internet: logging on, fail2ban
                     against password guessing, automatic security updates
    3) analysis-vm   for studying samples: logging ON (keeps the trail),
                     no automatic updates (snapshot and update by hand)
EOF
  while true; do
    read -r -p "    Choice [1]: " choice </dev/tty
    case "${choice:-1}" in
      1) profile=workstation ;;
      2) profile=server ;;
      3) profile=analysis-vm ;;
      *) echo "    Pick 1, 2 or 3."; continue ;;
    esac
    break
  done

  log "Remote access — who may connect to SSH and RDP?"
  if [[ -n "$CLIENT_IP" ]]; then
    default_choice=1
    cat <<EOF
    1) Only your current IP: $CLIENT_IP   (where this SSH session comes from)
    2) IPs or ranges you type in
    3) Anywhere   (not recommended on a public server: RDP uses your password)

    If your home IP changes often, use a range (2) or make sure you have
    console access at your provider — otherwise you can lock yourself out later.
EOF
  else
    cat <<EOF
    Not connected over SSH, so your public IP cannot be detected here.
    On the machine you will connect FROM, run:  curl -s https://ifconfig.me

    2) IPs or ranges you type in
    3) Anywhere   (not recommended on a public server: RDP uses your password)
EOF
  fi

  while true; do
    sources=()
    read -r -p "    Choice [$default_choice]: " choice </dev/tty
    choice="${choice:-$default_choice}"
    case "$choice" in
      1)
        if [[ -z "$CLIENT_IP" ]]; then echo "    Option 1 needs an SSH session."; continue; fi
        sources=("$CLIENT_IP") ;;
      2)
        echo "    One per line, e.g. 203.0.113.7 or 198.51.100.0/24. Empty line = done."
        while true; do
          read -r -p "    IP/range: " entry </dev/tty
          [[ -z "$entry" ]] && break
          if is_ip_or_cidr "$entry"; then
            sources+=("$entry")
          else
            echo "    \"$entry\" is not an IP address or range — try again."
          fi
        done
        if (( ${#sources[@]} == 0 )); then echo "    Nothing entered."; continue; fi ;;
      3) ;;
      *) echo "    Pick 1, 2 or 3."; continue ;;
    esac

    if (( ${#sources[@]} > 0 )) && ! warn_if_locked_out "${sources[@]}"; then
      ask_yn "Use this list anyway?" N || continue
    fi
    break
  done

  log "SSH login"
  if [[ -s "$keys" ]]; then
    echo "    $keys has $(grep -cE '^[^#[:space:]]' "$keys") key(s)."
    if ask_yn "Allow SSH logins with a key only (turn passwords off)?" N; then
      cat <<EOF
    Test it first. In a NEW terminal on your own machine, run:
        ssh $LOGIN_USER@${SERVER_IP:-<this-server>}
    It must log you in WITHOUT asking for this server's password
    (a passphrase for your own key is fine). Keep this session open meanwhile.
EOF
      if ask_yn "Did that log you in with your key?" N; then
        key_only=true
      else
        echo "    Keeping password login on. Fix the key, then: $0 --reconfigure"
      fi
    fi
  else
    cat <<EOF
    No SSH keys in $keys, so password login stays on.
    To switch to keys later, on your own machine run:
        ssh-copy-id $LOGIN_USER@${SERVER_IP:-<this-server>}
    and then:  $0 --reconfigure
EOF
  fi

  if ask_yn "Block SSH logins as root?" Y; then
    no_root=true
  fi

  {
    echo "# Written by bootstrap.sh — your answers, NOT committed (see .gitignore)."
    echo "# Change them with:  ./bootstrap/bootstrap.sh --reconfigure"
    echo "setup_profile: $profile"
    if (( ${#sources[@]} == 0 )); then
      echo "access_allowed_from: []"
    else
      echo "access_allowed_from:"
      for entry in "${sources[@]}"; do echo "  - \"$entry\""; done
    fi
    if [[ -n "$SERVER_PORT" ]]; then echo "ssh_port: $SERVER_PORT"; fi
    echo "ssh_key_only: $key_only"
    echo "ssh_disable_root_login: $no_root"
  } >"$LOCAL_VARS"
  chmod 600 "$LOCAL_VARS"
  log "Saved to local.yml"
}

CAN_ASK=0
[[ -t 0 && "$NO_PROMPT" -eq 0 ]] && CAN_ASK=1

if [[ -f "$LOCAL_VARS" && "$RECONFIGURE" -eq 0 ]]; then
  log "Using your saved settings (change with --reconfigure):"
  grep -v '^#' "$LOCAL_VARS" | sed 's/^/    /'
  # Your IP may have changed since you answered.
  SAVED=()
  while IFS= read -r line; do SAVED+=("$line"); done < <(saved_sources)
  if (( ${#SAVED[@]} > 0 )) && ! warn_if_locked_out "${SAVED[@]}"; then
    if (( CAN_ASK )) && ask_yn "Answer the questions again now?" Y; then
      configure_access
    elif (( CAN_ASK )) && ! ask_yn "Continue with the saved list anyway?" N; then
      exit 1
    fi
  fi
elif (( CAN_ASK )); then
  configure_access
elif [[ -f "$LOCAL_VARS" ]]; then
  log "Cannot ask here — keeping your saved settings in local.yml"
else
  log "No local.yml and no prompts — using group_vars defaults (workstation profile, SSH and RDP open to anyone, passwords on)"
fi

if [[ "${UBUNTU_SETUP_STOP_AFTER:-}" == "questions" ]]; then
  log "Stopping after the questions (UBUNTU_SETUP_STOP_AFTER)"
  exit 0
fi

# --- 3) Prime sudo -----------------------------------------------------------
log "Asking for your password once (needed for apt and systemctl)"
sudo -v
while true; do
  sudo -n true
  sleep 60
  kill -0 "$$" 2>/dev/null || exit
done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# --- 4) Ansible --------------------------------------------------------------
# community.general 10/11 (requirements.yml) needs ansible-core 2.16 or newer.
# Ubuntu 24.04's apt has 2.16; 22.04's apt has Ansible 2.10, which is far too
# old, so there we add the official Ansible PPA.
NEED_CORE="2.16"

# Prints nothing (and never fails) when Ansible is missing — with pipefail and
# set -e a failing `ansible --version` would otherwise end the script silently.
ansible_core_version() {
  { ansible --version 2>/dev/null || true; } | sed -n 's/.*core \([0-9][0-9.]*\).*/\1/p' | head -n1
}
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

log "Checking Ansible"
CORE="$(ansible_core_version)"
if [[ -z "$CORE" ]] || ! version_ge "$CORE" "$NEED_CORE"; then
  log "Installing Ansible (need ansible-core >= $NEED_CORE, found ${CORE:-none})"
  sudo apt-get update
  # Decide on the PPA BEFORE installing anything: putting the PPA's
  # ansible-core on top of 22.04's own Ansible 2.10 makes dpkg fail on
  # overlapping files.
  CANDIDATE="$(apt-cache policy ansible-core 2>/dev/null | awk '/Candidate:/ {print $2}')"
  CANDIDATE="${CANDIDATE%%-*}"
  if [[ -z "$CANDIDATE" || "$CANDIDATE" == "(none)" ]] || ! version_ge "$CANDIDATE" "$NEED_CORE"; then
    log "Ubuntu's Ansible is too old (${CANDIDATE:-none}) — using ppa:ansible/ansible"
    if dpkg-query -W -f='${Status}' ansible 2>/dev/null | grep -q "install ok installed"; then
      log "Removing the old Ansible package first"
      sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y ansible
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
    sudo add-apt-repository -y ppa:ansible/ansible
    sudo apt-get update
  fi
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ansible-core
  CORE="$(ansible_core_version)"
  if [[ -z "$CORE" ]] || ! version_ge "$CORE" "$NEED_CORE"; then
    log "ERROR: still no ansible-core >= $NEED_CORE (found ${CORE:-none})."
    exit 1
  fi
fi
log "ansible-core $CORE"

# Into the repo, not ~/.ansible: the playbook runs under sudo, where ~ is
# /root, so collections installed for your user were silently ignored and
# Ansible fell back to whatever old version the apt package bundles.
# ansible.cfg points collections_path here.
log "Installing required Ansible collections"
ansible-galaxy collection install -r "$REPO_ROOT/requirements.yml" -p "$REPO_ROOT/collections"

if [[ "${UBUNTU_SETUP_STOP_AFTER:-}" == "ansible" ]]; then
  log "Stopping after installing Ansible (UBUNTU_SETUP_STOP_AFTER)"
  exit 0
fi

# --- 5) Run playbook ---------------------------------------------------------
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
# sudo here reuses the tty credential from step 3 (no prompt), the play's
# become is a no-op because we are already root, and sudo sets SUDO_USER so
# the xrdp role still knows which real user gets ~/.xsession.
cd "$REPO_ROOT"
log "Running Ansible playbook (as root via sudo)"
EXTRA_VARS=()
[[ -f "$LOCAL_VARS" ]] && EXTRA_VARS=(-e "@$LOCAL_VARS")
sudo ansible-playbook playbook.yml "${EXTRA_VARS[@]}"

# --- 6) Verify ---------------------------------------------------------------
if [[ -x "$REPO_ROOT/verify.sh" ]]; then
  log "Verifying installation"
  "$REPO_ROOT/verify.sh" || log "Some checks failed — see the list above"
fi

log "Setup complete"
