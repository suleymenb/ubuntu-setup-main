# Test image: plain Ubuntu plus systemd as PID 1, so services, handlers and
# ufw behave like on a real machine. Used by tests/run.sh.
ARG RELEASE=24.04
FROM ubuntu:${RELEASE}

ENV DEBIAN_FRONTEND=noninteractive container=docker

# Only what the tests drive directly; Ansible itself is installed by
# bootstrap.sh inside the test, because that is part of what is tested.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus sudo ca-certificates curl gnupg git \
      python3 python3-yaml python3-jinja2 \
      ufw iptables openssh-server rsyslog util-linux lsb-release \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash demo \
 && echo 'demo ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/demo \
 && chmod 0440 /etc/sudoers.d/demo

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
