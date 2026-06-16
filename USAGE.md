# Usage Guide

## Prerequisites

- A running **frp server** (`frps`) accessible from the host running this container
- Docker with `--privileged` support

---

## 1. Prepare the instance name file

The instance name identifies this DinD node in all generated subdomains. It is mounted read-only so the container cannot modify its own identity.

```sh
echo "worker01" > ./instance-name
```

Use a short, DNS-safe name (alphanumeric and hyphens only).

---

## 2. Run the container

```sh
docker run -d --privileged \
  --name my-dind \
  -e FRP_SERVER_ADDR=frp.example.com \
  -e FRP_SERVER_PORT=7000 \
  -e FRP_TOKEN=your-secret-token \
  -e BASE_DOMAIN=my.local \
  -v $(pwd)/instance-name:/etc/instance/name:ro \
  -v dind-data:/var/lib/docker \
  dind-auto-frpc:latest
```

Or with Docker Compose (see `docker-compose.example.yml`).

---

## 3. Start inner containers

Any container started inside the DinD with a published port (`-p`) is automatically exposed:

```sh
# Start nginx inside the DinD, publish port 8080 → 80
docker exec my-dind docker run -d -p 8080:80 --name web nginx:alpine
```

Within a few seconds it becomes accessible at:

```
worker01-web-port8080.my.local
```

No labels, no extra config.

---

## URL Format

```
{instance-name}-{stack-name}-{container-name}-port{host-port}.{base-domain}
```

| Scenario | Command | URL |
|---|---|---|
| Plain `docker run` | `-p 8080:80 --name web` | `worker01-web-port8080.my.local` |
| Compose stack `myapp`, service `api` | `-p 3000:3000` | `worker01-myapp-api-port3000.my.local` |
| Multiple published ports | `-p 8080:80 -p 8443:443` | `worker01-web-port8080.my.local` + `worker01-web-port8443.my.local` |

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
| `BASE_DOMAIN` | yes | `my.local` | base domain for generated subdomains |

---

## Instance Name File

| Path inside container | `/etc/instance/name` |
|---|---|
| Mount flag | `:ro` (read-only) |
| Content | Single word, e.g. `worker01` |

```sh
# host side: create the file
echo "worker01" > /opt/dind/instance-name

# pass to container
-v /opt/dind/instance-name:/etc/instance/name:ro
```

---

## Using Docker Compose inside the DinD

Containers started with `docker compose up` inside the DinD are exposed automatically. The stack name comes from the `com.docker.compose.project` label, which Compose sets to the directory name by default.

```sh
# Copy a compose file into the DinD and start it
docker cp myapp/ my-dind:/myapp
docker exec my-dind sh -c "cd /myapp && docker compose up -d"
```

If the stack directory is `myapp` and the service is `web` with `-p 5000:5000`:

```
worker01-myapp-web-port5000.my.local
```

---

## Troubleshooting

**Container starts but URL not accessible:**
- Check frp server is running and reachable from the host
- Check `FRP_TOKEN` matches the server config
- Inspect frpc logs: `docker exec my-dind supervisorctl tail frpc`

**URL not generated after starting inner container:**
- Verify the inner container was started with `-p` (published port, not just `EXPOSE`)
- Check docker-gen logs: `docker exec my-dind supervisorctl tail docker-gen`
- Check generated config: `docker exec my-dind cat /etc/frpc/frpc.toml`

**Entrypoint fails on start:**
- Missing instance name file → mount `/etc/instance/name:ro`
- Missing env var → check all four required vars are set

**Verify processes are running:**
```sh
docker exec my-dind supervisorctl status
```
Expected output:
```
docker-gen                       RUNNING   pid ...
dockerd                          RUNNING   pid ...
frpc                             RUNNING   pid ...
```
