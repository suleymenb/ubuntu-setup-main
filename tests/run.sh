#!/usr/bin/env bash
# Runs the container tests for one Ubuntu release.
#
#   ./tests/run.sh 24.04        (default)
#   ./tests/run.sh 22.04
#   KEEP=1 ./tests/run.sh       leave the container running to poke around
#
# Needs Docker. The container runs systemd and is privileged, because ufw,
# sshd and fail2ban need real netfilter and services to be tested honestly.

set -euo pipefail

RELEASE="${1:-24.04}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="ubuntu-setup-test:${RELEASE}"
NAME="ubuntu-setup-test-${RELEASE//./}"

echo "==> Building $IMAGE"
docker build -q -t "$IMAGE" --build-arg "RELEASE=$RELEASE" "$REPO_ROOT/tests" >/dev/null

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  "$IMAGE" >/dev/null
if [[ "${KEEP:-0}" != "1" ]]; then
  trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
fi

echo "==> Waiting for systemd"
for _ in $(seq 1 30); do
  state="$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)"
  [[ "$state" == "running" || "$state" == "degraded" ]] && break
  sleep 1
done
echo "    systemd: ${state:-unknown}"

# A clean copy: no local.yml or collections from your own checkout.
echo "==> Copying the repo"
# COPYFILE_DISABLE keeps macOS's tar from adding its own metadata files.
COPYFILE_DISABLE=1 tar -C "$REPO_ROOT" --exclude=.git --exclude=collections --exclude=local.yml -cf - . \
  | docker exec -i "$NAME" bash -c 'mkdir -p /home/demo/repo \
      && tar --warning=no-unknown-keyword -C /home/demo/repo -xf - && chown -R demo: /home/demo/repo'

docker exec "$NAME" bash /home/demo/repo/tests/scenarios.sh
