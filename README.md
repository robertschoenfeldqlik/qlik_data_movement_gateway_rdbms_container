# Qlik Data Movement Gateway - All-in-One Docker Container

A single Docker container running the **Qlik Data Movement Gateway** alongside three RDBMS engines, built on Oracle Linux 9 with systemd as PID 1. Designed for demos, testing, and proof-of-concept environments.

## What's Inside

| Component | Version | Port | Credentials |
|-----------|---------|------|-------------|
| MySQL | 8.0 | 3306 | `root` / `Qlik1234` |
| PostgreSQL | 15 | 5432 | `postgres` / `Qlik1234` |
| SQL Server | 2022 (Developer) | 1433 | `sa` / `Qlik1234!` |
| Qlik Data Movement Gateway | Latest | 3552, 8080, 8088, 8686 | — |
| SSH | — | 22 | `qlikdmg` / `Qlik1234` |

MySQL is preconfigured with binary logging enabled (ROW format) for CDC replication and comes preloaded with a sample **churn** dataset.

## Prerequisites

- **Docker Desktop** (Windows/Mac) or **Docker Engine** (Linux) with at least **4 GB** of memory allocated
- **Qlik Cloud tenant** — you'll need your tenant URL (e.g., `your-tenant.us.qlikcloud.com`)
- **Qlik Data Movement Gateway RPM** — see [Downloading the Gateway RPM](#downloading-the-gateway-rpm) below

## Downloading the Gateway RPM

The Gateway RPM (`qlik-data-gateway-data-movement.rpm`) is not included in this repository and must be downloaded separately.

**Download from GitHub releases:**
> https://github.com/qlik-download/saas-download-links/releases

Look for the file named `qlik-data-gateway-data-movement.rpm` in the latest release assets.

After downloading, rename the file to `gateway.rpm` and place it in the `rpmfiles/` directory:

```
rpmfiles/
  gateway.rpm    <-- place the downloaded RPM here
```

Alternatively, the deploy scripts will prompt you to paste a download URL and will fetch the RPM automatically.

For full gateway documentation, see the official Qlik help:
> https://help.qlik.com/en-US/cloud-services/Subsystems/Hub/Content/Sense_Hub/Gateways/dm-gateway-setting-up.htm

## Quick Start

### Windows (PowerShell)

```powershell
.\deploy-qlik-dmg.ps1
```

### Mac / Linux (Bash)

```bash
chmod +x deploy-qlik-dmg.sh
./deploy-qlik-dmg.sh
```

Both scripts will:

1. Validate Docker is running and the Dockerfile is present
2. Prompt for the Gateway RPM (or use an existing one in `rpmfiles/`)
3. Prompt for your Qlik Cloud tenant URL
4. Configure host firewall rules for the required ports
5. Build the Docker image
6. Create a named volume for MySQL data persistence
7. Start the container and stream initialization logs
8. Display connection details and a gateway registration token

## Manual Build & Run

If you prefer to run Docker commands directly:

```bash
# Build
docker build -t qlik-dmg:latest .

# Run
docker run -d \
  --name qlik-dmg \
  --privileged \
  --cgroupns=host \
  --memory=4g \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v qlik-mysql-data:/var/lib/mysql \
  -e TENANT_URL="your-tenant.us.qlikcloud.com" \
  -p 22:22 -p 80:80 -p 443:443 \
  -p 3306:3306 -p 5432:5432 -p 1433:1433 \
  -p 3552:3552 -p 8080:8080 -p 8088:8088 -p 8686:8686 \
  qlik-dmg:latest
```

> **Note:** `--privileged` and `--cgroupns=host` are required because systemd runs as PID 1 inside the container. `--memory=4g` is required for SQL Server 2022 to start.

## Exposed Ports

| Port | Service |
|------|---------|
| 22 | SSH |
| 80 | HTTP |
| 443 | HTTPS |
| 1433 | SQL Server |
| 3306 | MySQL |
| 3552 | Qlik Data Movement Gateway |
| 5432 | PostgreSQL |
| 8080 | Qlik Gateway HTTP |
| 8088 | Qlik Gateway |
| 8686 | Qlik Gateway |

## Environment Variables

All credentials can be overridden at runtime with `docker run -e`:

| Variable | Default | Description |
|----------|---------|-------------|
| `TENANT_URL` | `qppqtcenterprise.us.qlikcloud.com` | Qlik Cloud tenant URL |
| `MYSQL_ROOT_PASSWORD` | `Qlik1234` | MySQL root password |
| `POSTGRES_PASSWORD` | `Qlik1234` | PostgreSQL superuser password |
| `MSSQL_SA_PASSWORD` | `Qlik1234!` | SQL Server SA password (must include a special character) |
| `MSSQL_PID` | `Developer` | SQL Server edition |

## Registering the Gateway in Qlik Cloud

After the container starts, the initialization logs will display a **registration token**. Use this token to register the gateway in your Qlik Cloud tenant:

1. Log into your Qlik Cloud tenant
2. Go to **Administration** > **Data Gateways**
3. Click **Register** and paste the token

If you missed the token, retrieve it manually:

```bash
docker exec -it qlik-dmg bash -c "cd /opt/qlik/gateway/movement/bin && ./agentctl qcs get_registration"
```

## Useful Commands

```bash
# Open a shell inside the container
docker exec -it qlik-dmg /bin/bash

# Tail container initialization logs
docker exec -it qlik-dmg journalctl -u qlik-dmg-init.service -f

# Tail SQL Server logs
docker exec -it qlik-dmg journalctl -u mssql-server -f

# Check repagent status
docker exec -it qlik-dmg systemctl status repagent

# Stop / remove the container
docker stop qlik-dmg
docker rm qlik-dmg

# Remove the MySQL data volume (deletes all data)
docker volume rm qlik-mysql-data
```

## Architecture

```
                    +------------------------------------+
                    |       Docker Container (qlik-dmg)  |
                    |       Oracle Linux 9 + systemd     |
                    |                                    |
  -e TENANT_URL --> |  /proc/1/environ                   |
                    |       |                            |
                    |  qlik-dmg-env.service              |
                    |       | (captures env vars)        |
                    |       v                            |
                    |  /etc/qlik-dmg.env                 |
                    |       |                            |
                    |  qlik-dmg-init.service             |
                    |       | (runs entrypoint.sh)       |
                    |       v                            |
                    |  +----------+  +--------------+    |
                    |  | MySQL    |  | PostgreSQL   |    |
                    |  | :3306    |  | :5432        |    |
                    |  +----------+  +--------------+    |
                    |  +----------+  +--------------+    |
                    |  | MSSQL    |  | Qlik Gateway |    |
                    |  | :1433    |  | :3552/8080/  |    |
                    |  |          |  |  8088/8686   |    |
                    |  +----------+  +--------------+    |
                    |  +----------+                      |
                    |  | SSH :22  |                      |
                    |  +----------+                      |
                    +------------------------------------+
```

Systemd is PID 1. Docker environment variables are captured via `/proc/1/environ` into `/etc/qlik-dmg.env` by a oneshot service, then the init service sources that file and starts all databases and the gateway in sequence.

## File Structure

```
.
├── Dockerfile               # Image definition (Oracle Linux 9 + systemd)
├── deploy-qlik-dmg.sh       # Deployment script (Mac/Linux)
├── deploy-qlik-dmg.ps1      # Deployment script (Windows)
├── entrypoint.sh            # Container initialization (called by systemd)
├── qlik-dmg-init.service    # Systemd service unit for initialization
├── custom.cnf               # MySQL config (enables binary log for CDC)
├── churn-dump.sql           # Sample MySQL dataset
├── rpmfiles/
│   └── gateway.rpm          # <-- Place the Qlik Gateway RPM here
└── README.md
```

## Troubleshooting

**SQL Server won't start:** Ensure the container has at least 4 GB of memory (`--memory=4g`). The SA password must contain uppercase, lowercase, a digit, and a special character.

**repagent fails to start:** The entrypoint automatically applies a systemd override (`Type=forking`, `TimeoutStartSec=120`). If you need to re-apply it manually on a running container:

```bash
docker exec -it qlik-dmg bash -c "mkdir -p /etc/systemd/system/repagent.service.d && \
cat > /etc/systemd/system/repagent.service.d/override.conf << 'EOF'
[Service]
PIDFile=
Type=forking
TimeoutStartSec=120
EOF
systemctl daemon-reload && systemctl restart repagent"
```

**Gateway not installed:** The `rpmfiles/` directory must contain a valid `gateway.rpm` before building the image. Verify with: `file rpmfiles/gateway.rpm` (should report "RPM").

**Can't connect to databases from host:** Check that the host firewall allows traffic on ports 3306, 5432, and 1433. The deploy scripts attempt to configure this automatically.
