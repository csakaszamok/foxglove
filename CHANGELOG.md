# Changelog

## 0.10.0

### Added
- The `-sysbox` image has `docker compose` and `docker buildx`, as `-dind` does: a stack
  can be brought up inside the sandbox (`docker compose up`), with `build:` too.

## 0.9.0

### Changed (breaking)
- Only the `p9m.subdomain` label names a container's proxy `<instance>-<subdomain>`;
  `p7y.subdomain` and `frpc.subdomain` are ignored (the container gets its generated name).
- foxglove is now the sandbox image of Purgatorium (p9m): images move to
  `ghcr.io/csakaszamok/foxglove:<version>-dind` / `-sysbox`. 0.7.0 and 0.8.0 stay at
  `ghcr.io/p7y-dev/foxglove`.

## 0.8.0

### Added
- `p7y.subdomain` label: names a container's proxy `<instance>-<subdomain>`, like
  `frpc.subdomain`, which keeps working as its older name. When a container has
  both, `p7y.subdomain` wins.

## 0.7.0

### Changed (breaking)
- Ports an inner container publishes on a loopback address (`-p 127.0.0.1:5678:5678`,
  `127.x.x.x`, `[::1]`) no longer get an frp proxy: they are private to the sandbox.
  Only ports published on all interfaces (`-p 5678:5678`, Docker's `HostIP` `""`,
  `0.0.0.0` or `::`) are exposed, with the same proxy names as before.
  A container whose ports are all on loopback gets no proxy, also with an
  `frpc.subdomain` label. Stacks that relied on `127.0.0.1:` links must publish
  on all interfaces instead.
- Images move to `ghcr.io/p7y-dev/foxglove:<version>-dind` / `-sysbox`, built by
  GitHub Actions on a `v*` tag. The old `csakaszamok/foxglove` images stay on
  Docker Hub; `upload-docker.sh` is deprecated.
- Licensed under Apache-2.0, with a NOTICE file; the names "Purgatory" and
  "p7y" are not licensed for use as the name of another product.

### Added
- Readiness marker proxy `<instance>.ready` (type `stcp`, random secret, not
  reachable). It is registered as soon as docker-gen's generated config is
  applied, also when no port is exposed, so a healthcheck can use
  `wget -qO- http://<frps>:7500/api/proxy/stcp | grep -q online` instead of
  waiting for an HTTP proxy that may never come.

### Known limitation
- docker-gen reports only the first host binding of each container port. A
  container port published both on loopback and on all interfaces
  (`-p 127.0.0.1:5680:80 -p 5681:80`) may get no proxy for the all-interface
  binding. Publish each container port one way only.

## 0.6.0

### Added
- Key-only root SSH: `sshd` on port 22, keys from `/etc/instance/authorized_keys`
  (re-read on every login), host keys persisted in `/etc/ssh/host-keys`.
