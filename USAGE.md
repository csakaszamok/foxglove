# Usage Guide

## Prerequisites

- A running **frp server** (`frps`) accessible from the host
- For the `dind` variant: Docker with `--privileged` support
- For the `sysbox` variant: [Sysbox runtime](https://github.com/nestybox/sysbox) installed on the host

---

## 1. Prepare the instance name file

The instance name identifies this node in all generated subdomains. It is mounted read-only so the container cannot modify its own identity.

```sh
echo "worker01" > ./instance-name
```

Use a short, DNS-safe name (alphanumeric and hyphens only).

---

## 2. Run the container

**DinD variant** (standard Docker, requires `--privileged`):
```sh
docker run -d --privileged \
  --name foxglove \
  -e FRP_SERVER_ADDR=frp.example.com \
  -e FRP_SERVER_PORT=7000 \
  -e FRP_TOKEN=your-secret-token \
  -e BASE_DOMAIN=example.com \
  -v $(pwd)/instance-name:/etc/instance/name:ro \
  -v foxglove-data:/var/lib/docker \
  csakaszamok/foxglove:5-dind
```

**Sysbox variant** (no `--privileged` needed):
```sh
docker run -d --runtime=sysbox-runc \
  --name foxglove \
  -e FRP_SERVER_ADDR=frp.example.com \
  -e FRP_SERVER_PORT=7000 \
  -e FRP_TOKEN=your-secret-token \
  -e BASE_DOMAIN=example.com \
  -v $(pwd)/instance-name:/etc/instance/name:ro \
  -v foxglove-data:/var/lib/docker \
  csakaszamok/foxglove:5-sysbox
```

Or with Docker Compose — copy `docker-compose.example.yml` to `docker-compose.yml` and fill in the values.

---

## 3. Start inner containers

Any container started inside with a published port (`-p`) is automatically exposed:

```sh
# Start nginx inside, publish port 8080 → 80
docker exec foxglove docker run -d -p 8080:80 --name web nginx:alpine
```

Within a few seconds it becomes accessible at:

```
worker01-web-port8080.example.com
```

No labels, no extra config.

---

## URL Format

```
{instance-name}-{stack-name}-{container-name}-port{host-port}.{base-domain}
```

| Scenario | Command | URL |
|---|---|---|
| Plain `docker run` | `-p 8080:80 --name web` | `worker01-web-port8080.example.com` |
| Compose stack `myapp`, service `api` | `-p 3000:3000` | `worker01-myapp-api-port3000.example.com` |
| Multiple published ports | `-p 8080:80 -p 8443:443` | `worker01-web-port8080.example.com` + `worker01-web-port8443.example.com` |

**Name sanitization rules:**
- Non-alphanumeric characters → `-`
- Lowercased
- Stack name from `com.docker.compose.project` label (Compose sets this automatically)

---

## Environment Variables

| Variable | Required | Example | Description |
|---|---|---|---|
| `FRP_SERVER_ADDR` | yes | `frp.example.com` | frp server hostname or IP |
| `FRP_SERVER_PORT` | yes | `7000` | frp server port |
| `FRP_TOKEN` | yes | `s3cr3t` | frp authentication token |
| `BASE_DOMAIN` | yes | `example.com` | base domain for generated subdomains |

---

## Instance Name File

| Path inside container | `/etc/instance/name` |
|---|---|
| Mount flag | `:ro` (read-only) |
| Content | Single word, e.g. `worker01` |

```sh
echo "worker01" > /opt/foxglove/instance-name
-v /opt/foxglove/instance-name:/etc/instance/name:ro
```

---

## Using Docker Compose inside the container

```sh
docker cp myapp/ foxglove:/myapp
docker exec foxglove sh -c "cd /myapp && docker compose up -d"
```

If the stack directory is `myapp` and the service is `web` with `-p 5000:5000`:

```
worker01-myapp-web-port5000.example.com
```

---

## Troubleshooting

**Container starts but URL not accessible:**
- Check frp server is running and reachable
- Check `FRP_TOKEN` matches the server config
- Inspect frpc logs: `docker exec foxglove supervisorctl tail frpc`

**URL not generated after starting inner container:**
- Verify the inner container was started with `-p` (published port, not just `EXPOSE`)
- Check docker-gen logs: `docker exec foxglove supervisorctl tail docker-gen`
- Check generated config: `docker exec foxglove cat /etc/frpc/frpc.toml`

**Entrypoint fails on start:**
- Missing instance name file → mount `/etc/instance/name:ro`
- Missing env var → check all four required vars are set

**Verify processes are running:**
```sh
docker exec foxglove supervisorctl status
```
Expected output:
```
docker-gen                       RUNNING   pid ...
dockerd                          RUNNING   pid ...
frpc                             RUNNING   pid ...
```
