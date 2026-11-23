# ubuntu-setup

Turns a headless Ubuntu server into a machine you can reach over RDP. Installs
LXDE, boots into the graphical target, and sets up xrdp. Safe to re-run.

Tested on Ubuntu 22.04 and 24.04 — on every push, see [CI](#ci). `eza` is
only packaged from 24.04 on, so 22.04 skips it (it is in
`apps_optional_packages`). On arm64,
Obsidian is installed from its AppImage (there is no arm64 `.deb`).

## Quick start

```bash
cd ~ && git clone https://github.com/suleymenb/ubuntu-setup-main.git && cd ubuntu-setup-main && chmod +x bootstrap/bootstrap.sh verify.sh && ./bootstrap/bootstrap.sh
```

Clone from your home directory — `git` creates the subfolder. Cloning from
inside an existing copy nests the repo in itself; `bootstrap.sh` refuses to run
if it detects that.

Run it as your **normal user**, not as root — the RDP session is configured for
whoever runs it. The script asks for your password once and uses sudo where
needed.

Before it installs anything it asks what kind of machine this is (see
[Profiles](#profiles)), who may connect, whether SSH should be key-only, and
whether to block root over SSH (see [Remote access](#remote-access)).

## What it does

| Role | |
|---|---|
| **preflight** | Ubuntu/Debian, root, disk space, apt mirrors, package names |
| **desktop** | Installs LXDE, sets the default systemd target to `graphical.target` |
| **apps** | VLC, VeraCrypt (PPA), C + cross-compile toolchain, offensive-sec tools, terminal tools, Shodan CLI, CLion (snap), Obsidian (GitHub release) |
| **jetbrains** | Extra JetBrains IDEs from the unofficial jetbrains-ppa — none by default (CLion comes from the snap) |
| **virtualisation** | QEMU/KVM, virt-manager, libvirt groups, KVM acceleration check |
| **zsh** | Oh My Zsh + plugins for the login user, made the default shell (opt-out) |
| **dotfiles** | Your own dotfiles repo, cloned and linked into your home — skipped until you set one |
| **xrdp** | Installs xrdp, enables and starts it |
| **access** | ufw rules for SSH and RDP (optionally only from your IPs), SSH key-only / no-root login |
| **updates** | Automatic security updates (unattended-upgrades), optional auto-reboot |
| **fail2ban** | Bans addresses after repeated failed SSH/RDP logins (server profile) |
| **hardening** | Disable sleep, logging off/on per profile, ufw deny-incoming — runs last |

Beyond the bare commands, the xrdp role also does the two things that decide
whether RDP actually works:

- Writes `~/.xsession` with `startlxde`. Without it you log in successfully and
  get an **empty grey screen** — the most common "xrdp is broken" report.
- Adds the `xrdp` user to the `ssl-cert` group so it can read
  `/etc/ssl/private/ssl-cert-snakeoil.key`. Without it clients hit TLS errors.

## Reboot

`systemctl set-default graphical.target` only takes effect at boot, so the
playbook records that a reboot is due and tells you at the end.

It does **not** reboot by default. Rebooting mid-play kills the connection
Ansible is running over, and on a remote host that is how you lose a session
with no idea whether the run finished. To opt in:

```yaml
# group_vars/all.yml
ubuntu_auto_reboot: true
```

## Connecting

After the reboot, from any RDP client (Microsoft Remote Desktop, Remmina):

```
<server-ip>:3389
```

Log in with your normal Linux username and password.

## Profiles

One setting, `setup_profile`, picks sensible defaults for the kind of
machine. `bootstrap.sh` asks for it; each setting can still be overridden on
its own in `group_vars/all.yml` or `local.yml`.

| | logging | fail2ban | automatic updates |
|---|---|---|---|
| `workstation` (default) | off (anti-forensics) | off | on |
| `server` | on | on | on |
| `analysis-vm` | **on** — keep the trail of what a sample did | off | **off** — the VM must not change underneath an analysis |

fail2ban needs logs, so preflight refuses `fail2ban_enabled` together with
`hardening_disable_logging`. Switching a machine from `workstation` to another
profile turns logging back on (logs that were already wiped stay gone).

Automatic updates install security updates only, daily. They do not reboot by
default — a surprise reboot drops your RDP session. Set
`updates_auto_reboot: true` (at `updates_reboot_time`) if you prefer that;
otherwise `verify.sh` warns when `/var/run/reboot-required` appears.

## Remote access

The hardening role switches the firewall to "deny incoming", so this playbook
decides who can still get in. `bootstrap.sh` asks on the first run:

1. **Who may connect to SSH and RDP** — only the IP you are SSH'd in from
   (detected automatically), IPs/ranges you type in, or anywhere. If the list
   would shut out the SSH session you are running it from, it says so and asks
   again.
2. **Key-only SSH** — only offered when `~/.ssh/authorized_keys` has a key, and
   only switched on after you confirm a key login works from a second
   terminal.
3. **Block root login over SSH.**

Your answers go to `local.yml` (git-ignored — your IP never ends up in the
repo). Re-runs reuse them; change them with:

```bash
./bootstrap/bootstrap.sh --reconfigure
```

Safety nets, in the playbook itself:

- SSH is always allowed through ufw (`access_allow_ssh: true`), and the
  hardening role **refuses to enable ufw** if no SSH rule exists.
- Preflight refuses `ssh_key_only: true` while the login user has no
  authorized key.
- New allow rules are added before old ones are removed, and only rules this
  playbook created (comment `ubuntu-setup …`) are ever removed.
- The SSH policy is a drop-in (`/etc/ssh/sshd_config.d/00-ubuntu-setup.conf`),
  checked with `sshd -t` before it is written, and applied with a reload, so
  your current session stays up.

RDP always uses your Linux password, so on a public server restricting the
source IPs is what actually protects it — with the `server` profile, fail2ban
also bans an address after 5 failed logins within 10 minutes (your allowed
addresses are never banned).

### Your own RDP certificate

xrdp uses Ubuntu's self-signed certificate by default, so every client warns
— and a real man-in-the-middle warning looks exactly the same. Point it at
your own certificate (paths on the server, e.g. from certbot):

```yaml
xrdp_tls_cert: /etc/letsencrypt/live/rdp.example.com/fullchain.pem
xrdp_tls_key:  /etc/letsencrypt/live/rdp.example.com/privkey.pem
```

The files are copied into `/etc/xrdp`, because xrdp cannot read
`/etc/letsencrypt/live`. Re-run `--tags xrdp` after a renewal.

## Dotfiles

Keep your own `.tmux.conf`, aliases and so on in a git repo, and every new
machine gets them:

```yaml
dotfiles_repo: https://github.com/<you>/dotfiles.git
dotfiles_links:
  .tmux.conf: tmux/tmux.conf
  .zshrc: zsh/zshrc
# or, if the repo has its own installer:
dotfiles_install_command: ./install.sh
```

The repo is cloned to `~/.dotfiles` and updated on every run (git refuses if
you have uncommitted changes there, rather than overwriting them). An existing
file is moved to `<name>.before-dotfiles` once, never deleted. Once `.zshrc`
or `.tmux.conf` is linked from your repo, the zsh role stops editing it.

## Customising

**Edit `group_vars/all.yml`. Nothing else.** The roles install from those
lists, preflight validates them, and `verify.sh` reads the same file — so they
cannot drift apart.

Swapping LXDE for XFCE, for example:

```yaml
desktop_packages:
  - xfce4
xrdp_session_command: "startxfce4"
```

Adding an app is one line — plain apt packages go in `apps_packages`, anything
needing a PPA adds it to `apps_ppas` first (preflight adds PPAs *before* it
validates names, otherwise `veracrypt` would look like a typo).

Snaps go in `apps_snaps`; `classic: true` maps to `--classic`, which IDEs need:

```yaml
apps_snaps:
  - name: clion
    classic: true
```

Apps with no apt source at all come from their GitHub release:

```yaml
apps_github_debs:
  - name: obsidian
    repo: obsidianmd/obsidian-releases
    asset_match: 'amd64\.deb'
    architectures: [amd64]
```

The version is resolved from the GitHub API at run time, so it never goes
stale, and the installed version is compared first — otherwise every run would
re-download ~85 MB just to find nothing changed.

## Running

Via the bootstrap script — **no sudo in front**, it handles that itself:

```bash
./bootstrap/bootstrap.sh
```

Or calling Ansible directly, which *does* need sudo:

```bash
sudo ansible-playbook playbook.yml -e @local.yml               # everything
sudo ansible-playbook playbook.yml -e @local.yml --tags access  # one role
sudo ansible-playbook playbook.yml -e @local.yml --check        # dry run
./verify.sh                                                      # health check
```

Leave out `-e @local.yml` if you never ran `bootstrap.sh` — then the defaults
in `group_vars/all.yml` apply (SSH and RDP open to anyone, passwords on).
`verify.sh` reads `local.yml` itself; run it after a `sudo` to also check the
firewall rules.

The `sudo` there is deliberate. The two obvious alternatives both fail on
Ubuntu:

- **Plain `ansible-playbook`**: Ubuntu's sudo uses `tty_tickets`, so a
  credential cached in your terminal does not apply to the non-tty sudo Ansible
  spawns → `sudo: interactive authentication is required`.
- **`ansible-playbook -K`**: some PAM stacks answer Ansible's custom sudo
  prompt with a *second* `Password:` prompt that Ansible cannot answer →
  `Timed out waiting for become success`.

Running the whole playbook as root sidesteps both: the play's `become` is a
no-op, and sudo sets `SUDO_USER` so the xrdp role still knows which real user
gets `~/.xsession`.

Tags: `desktop`, `apps`, `jetbrains`, `virtualisation`, `zsh`, `dotfiles`,
`xrdp`, `access` (also `ssh`), `updates`, `fail2ban`, `hardening`. Preflight
always runs. `--tags xrdp` also runs `access`, because that is where the RDP
port is opened, and `--tags access` also runs `fail2ban`, which must not ban
the addresses you allow in.

**Secrets — never commit them.** The Shodan API key is not stored in the repo.
Pass it at run time, or export it, or skip it:

```bash
export SHODAN_API_KEY=your_key
sudo -E ansible-playbook playbook.yml        # -E keeps the env var
# or:
sudo ansible-playbook playbook.yml -e shodan_api_key=your_key
```

## How it fails

**Preflight** runs first and validates the OS, root access, disk space, apt
mirror reachability, and that every package name resolves. If preflight fails,
nothing else runs — that is deliberate.

**Every other role** is wrapped in `block`/`rescue`. A failing role is recorded
and the play continues, so one broken role never hides the state of the rest.
At the end you get a single report and a non-zero exit.

**`verify.sh`** checks the result independently of Ansible: packages, systemd
target, xrdp enabled/running/listening, the `ssl-cert` group, `~/.xsession`,
and the firewall rule. Exits non-zero on failure, so it works in CI.

## Troubleshooting

**Grey screen after logging in over RDP**
`~/.xsession` is missing or points at a desktop that is not installed:

```bash
echo "startlxde" > ~/.xsession
sudo systemctl restart xrdp
```

**TLS or certificate errors on connect**

```bash
sudo adduser xrdp ssl-cert
sudo systemctl restart xrdp
```

**Connection refused**
Check the service and the firewall. If you restricted access, your IP may have
changed — `curl -s https://ifconfig.me` on your own machine shows the current
one:

```bash
systemctl status xrdp
sudo ufw status
./bootstrap/bootstrap.sh --reconfigure
```

**Locked out of SSH**
Use your provider's web/serial console (or the physical machine), then either
allow your new IP or turn the restriction off:

```bash
sudo ufw allow from <your-ip> to any port 22 proto tcp
sudo rm /etc/ssh/sshd_config.d/00-ubuntu-setup.conf && sudo systemctl reload ssh   # passwords back on
```

**`sudo: interactive authentication is required` or `Timed out waiting for become success`**
You ran `ansible-playbook` without sudo, or with `-K` on a PAM stack that
double-prompts. Run it as root instead:

```bash
sudo ansible-playbook playbook.yml
```

**virt-manager shows no hypervisor, or every action asks for a password**
Group membership only applies to new sessions. Log out and back in:

```bash
id -nG        # should list libvirt and kvm
```

**QEMU is extremely slow**
No `/dev/kvm`, so it is emulating rather than accelerating. If this host is
itself a VM, enable nested virtualisation on the hypervisor:

```bash
kvm-ok
ls -l /dev/kvm
```

**`Unable to get required signing key` when adding a PPA**
That is the `apt_repository` module falling back to the legacy gpg keyserver
protocol on port 80. This playbook uses `add-apt-repository` instead, which
goes through the Launchpad API over HTTPS. If you hit it in your own tasks:

```bash
sudo add-apt-repository -y ppa:unit193/encryption
```

**Still text-only after a reboot**

```bash
systemctl get-default          # should be graphical.target
sudo systemctl set-default graphical.target
```

## Layout

```
group_vars/all.yml          every package name — the only file to edit
local.yml                   your bootstrap answers (git-ignored, overrides the above)
playbook.yml                role order + final failure report
bootstrap/bootstrap.sh      first-run setup, guards against nested clones
verify.sh                   post-run health check
roles/
  preflight/                validates everything up front (not wrapped)
  desktop/ apps/ jetbrains/ virtualisation/ zsh/ dotfiles/ xrdp/ access/
  updates/ fail2ban/ hardening/
    tasks/main.yml          block/rescue wrapper
    tasks/tasks.yml         the actual work
  xrdp/handlers/            restart xrdp only when something changed
  access/handlers/          reload sshd only when the login policy changed
tests/                      container tests, also run by CI
.github/workflows/ci.yml    lint, container tests and a full run per Ubuntu release
collections/                pinned collections, installed by bootstrap.sh (git-ignored)
```

## Notes

- Everything runs as root via `become: true` in `ansible.cfg`.
- `systemctl set-default` has no Ansible module, so the current target is read
  first and only written when it differs — otherwise every run would report
  "changed" and you could never spot a real one.
- The firewall rule is only applied when ufw is installed *and* active.

## CI

`.github/workflows/ci.yml` runs on every push and pull request:

- **lint** — `ansible-lint`, `yamllint` and `shellcheck`.
- **container tests** — `tests/run.sh` in Ubuntu 22.04 and 24.04 containers:
  the access, fail2ban, updates and hardening roles against a real ufw and
  sshd (lockout guards included), and `bootstrap.sh`'s questions driven
  through a terminal. Run them locally with Docker:

  ```bash
  ./tests/run.sh 24.04
  ```

- **full run** — the real `bootstrap.sh --no-prompt` and `verify.sh` on
  GitHub's Ubuntu 22.04 and 24.04 runners (actual VMs with systemd), then the
  playbook a second time to report anything that is not idempotent.

## License

MIT
