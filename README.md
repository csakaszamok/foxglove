# foxglove

Docker image that automatically exposes every inner container's published ports as frp HTTP proxies. No configuration needed — just use `-p` when starting containers inside the environment.

## Variants

| Tag | Base | Isolation | Requirement | Use case |
|-----|------|-----------|-------------|----------|
| `5-sysbox` | `alpine:3.21` | [Sysbox runtime](https://github.com/nestybox/sysbox) | Sysbox installed on host | **Recommended for production** |
| `5-dind` | `docker:dind` | Docker-in-Docker | `--privileged` | Development, Windows, or hosts without Sysbox |

**Sysbox is the recommended variant** — it runs without `--privileged`, which is safer for production environments. Use the `dind` variant on Windows or on Linux hosts where installing Sysbox is not an option.

## Quick Start

1. Create a file with your instance name (identifies this node in subdomains):
   ```sh
   echo "worker01" > ./instance-name
   ```

2. Run the container:

   **Sysbox (recommended):**
   ```sh
   docker run -d --runtime=sysbox-runc \
     -e FRP_SERVER_ADDR=frp.example.com \
     -e FRP_SERVER_PORT=7000 \
     -e FRP_TOKEN=your-secret-token \
     -e BASE_DOMAIN=example.com \
     -v $(pwd)/instance-name:/etc/instance/name:ro \
     csakaszamok/foxglove:5-sysbox
   ```

   **DinD (development / Windows):**
   ```sh
   docker run -d --privileged \
     -e FRP_SERVER_ADDR=frp.example.com \
     -e FRP_SERVER_PORT=7000 \
     -e FRP_TOKEN=your-secret-token \
     -e BASE_DOMAIN=example.com \
     -v $(pwd)/instance-name:/etc/instance/name:ro \
     csakaszamok/foxglove:5-dind
   ```

3. Start any container inside with a published port:
   ```sh
   docker exec <container> docker run -d -p 8080:80 nginx
   ```

   It becomes accessible immediately at:
   ```
   worker01-nginx-port8080.example.com
   ```

## URL Format

```
{instance-name}-{stack-name}-{container-name}-port{host-port}.{base-domain}
```

| Scenario | Example URL |
|---|---|
| Plain `docker run` | `worker01-nginx-port8080.example.com` |
| Docker Compose stack `myapp` | `worker01-myapp-nginx-port8080.example.com` |

Rules: non-alphanumeric characters in names are replaced with `-`, lowercased.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `FRP_SERVER_ADDR` | yes | frp server hostname or IP |
| `FRP_SERVER_PORT` | yes | frp server port (typically `7000`) |
| `FRP_TOKEN` | yes | frp authentication token |
| `BASE_DOMAIN` | yes | base domain for generated subdomains |

## Instance Name File

Mount a plain text file containing the instance identifier as **read-only**:

```sh
-v /path/to/name-file:/etc/instance/name:ro
```

The file should contain a single word, e.g. `worker01`. Read-only prevents the container from modifying its own identity.

## How It Works

Three processes run under supervisord:

1. **dockerd** — the inner Docker daemon
2. **frpc** — frp client, connected to your frp server
3. **docker-gen** — watches the Docker socket; whenever a container with published ports starts or stops, regenerates `/etc/frpc/frpc.toml` and hot-reloads frpc via its admin API

Only ports published with `-p` are exposed. `EXPOSE`-only ports are ignored.
