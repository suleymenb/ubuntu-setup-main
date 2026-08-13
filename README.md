# ubuntu-setup

Turns a headless Ubuntu server into a machine you can reach over RDP. Installs
LXDE, boots into the graphical target, and sets up xrdp. Safe to re-run.

Tested on Ubuntu 22.04 and 24.04.

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

## What it does

| Role | |
|---|---|
| **preflight** | Ubuntu/Debian, root, disk space, apt mirrors, package names |
| **desktop** | Installs LXDE, sets the default systemd target to `graphical.target` |
| **apps** | VLC, VeraCrypt (PPA), C + cross-compile toolchain, offensive-sec tools, terminal tools, Shodan CLI, CLion (snap), Obsidian (GitHub release) |
| **jetbrains** | JetBrains IDEs from the official apt repo (CLion by default) |
| **virtualisation** | QEMU/KVM, virt-manager, libvirt groups, KVM acceleration check |
| **zsh** | Oh My Zsh + plugins for the login user, optional default shell |
| **xrdp** | Installs xrdp, enables and starts it, opens port 3389 in ufw |
| **hardening** | Disable sleep/logging, ufw deny-incoming — runs last, all opt-out |

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
sudo ansible-playbook playbook.yml              # everything
sudo ansible-playbook playbook.yml --tags xrdp  # one role
sudo ansible-playbook playbook.yml --check      # dry run
./verify.sh                                     # health check, no sudo
```

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

Tags: `desktop`, `apps`, `jetbrains`, `virtualisation`, `zsh`, `xrdp`,
`hardening`. Preflight always runs.

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
Check the service and the firewall:

```bash
systemctl status xrdp
sudo ufw status
sudo ufw allow 3389/tcp
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
playbook.yml                role order + final failure report
bootstrap/bootstrap.sh      first-run setup, guards against nested clones
verify.sh                   post-run health check
roles/
  preflight/                validates everything up front (not wrapped)
  desktop/ apps/ jetbrains/ virtualisation/ zsh/ xrdp/ hardening/
    tasks/main.yml          block/rescue wrapper
    tasks/tasks.yml         the actual work
  xrdp/handlers/            restart xrdp only when something changed
```

## Notes

- Everything runs as root via `become: true` in `ansible.cfg`.
- `systemctl set-default` has no Ansible module, so the current target is read
  first and only written when it differs — otherwise every run would report
  "changed" and you could never spot a real one.
- The firewall rule is only applied when ufw is installed *and* active.

## License

MIT
