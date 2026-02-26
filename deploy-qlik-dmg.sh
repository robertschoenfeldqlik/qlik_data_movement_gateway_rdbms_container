#!/usr/bin/env bash
# =============================================================================
# Qlik Data Movement Gateway - Docker Deployment Script (Mac / Linux)
# Run this script from the directory containing your Dockerfile
# Usage: ./deploy-qlik-dmg.sh
# =============================================================================
set -euo pipefail

# -- Configuration ------------------------------------------------------------
IMAGE_NAME="qlik-dmg"
IMAGE_TAG="latest"
CONTAINER_NAME="qlik-dmg"
MYSQL_VOLUME="qlik-mysql-data"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPM_FOLDER="${SCRIPT_DIR}/rpmfiles"
RPM_TARGET="${RPM_FOLDER}/gateway.rpm"

# Change to script directory so Docker build context is correct
cd "$SCRIPT_DIR"
echo "==> Working directory: $SCRIPT_DIR"

# -- Helper Functions ---------------------------------------------------------
write_step() {
    echo ""
    echo -e "\033[36m==> $1\033[0m"
}

write_success() {
    echo -e "\033[32m    $1\033[0m"
}

write_fail() {
    echo -e "\033[31m    ERROR: $1\033[0m"
    exit 1
}

write_warn() {
    echo -e "\033[33m    $1\033[0m"
}

write_dim() {
    echo -e "\033[90m    $1\033[0m"
}

# -- Preflight Checks ---------------------------------------------------------
write_step "Running preflight checks..."

if ! command -v docker &>/dev/null; then
    write_fail "Docker is not installed or not in PATH. Please install Docker Desktop."
fi

if ! docker info &>/dev/null; then
    write_fail "Docker daemon is not running. Please start Docker Desktop and try again."
fi
write_success "Docker is running."

if [[ ! -f "./Dockerfile" ]]; then
    write_fail "Dockerfile not found in the current directory: $(pwd)"
fi
write_success "Dockerfile found."

# -- Gateway RPM --------------------------------------------------------------
write_step "Gateway RPM Setup"

GATEWAY_URL=""

if [[ -f "$RPM_TARGET" ]]; then
    FILE_SIZE_MB=$(awk "BEGIN {printf \"%.1f\", $(stat -f%z "$RPM_TARGET" 2>/dev/null || stat -c%s "$RPM_TARGET" 2>/dev/null) / 1048576}")
    write_warn "Found existing gateway.rpm (${FILE_SIZE_MB} MB) in $RPM_FOLDER"
    read -rp "    Use existing RPM? (Y to keep / N to re-download): " USE_EXISTING
    if [[ ! "$USE_EXISTING" =~ ^[Yy]$ ]]; then
        read -rp "    Paste the Gateway RPM download URL: " GATEWAY_URL
    fi
else
    write_warn "No gateway.rpm found in $RPM_FOLDER"
    read -rp "    Paste the Gateway RPM download URL: " GATEWAY_URL
fi

# Function to validate RPM magic bytes (0xED 0xAB 0xEE 0xDB)
validate_rpm() {
    local file="$1"
    local magic
    magic=$(xxd -l 4 -p "$file" 2>/dev/null || od -A n -t x1 -N 4 "$file" 2>/dev/null | tr -d ' ')
    if [[ "$magic" == "edabeedb" ]]; then
        return 0
    else
        return 1
    fi
}

if [[ -n "$GATEWAY_URL" ]]; then
    GATEWAY_URL=$(echo "$GATEWAY_URL" | xargs)   # trim whitespace
    if [[ -z "$GATEWAY_URL" ]]; then
        write_fail "No URL entered. Cannot build image without gateway.rpm."
    fi

    write_dim "Downloading from : $GATEWAY_URL"
    write_dim "Saving to        : $RPM_TARGET"

    mkdir -p "$RPM_FOLDER"

    if curl -fSL -o "$RPM_TARGET" "$GATEWAY_URL"; then
        if [[ ! -f "$RPM_TARGET" ]]; then
            write_fail "Download appeared to succeed but file not found at: $RPM_TARGET"
        fi

        if validate_rpm "$RPM_TARGET"; then
            FILE_SIZE_MB=$(awk "BEGIN {printf \"%.1f\", $(stat -f%z "$RPM_TARGET" 2>/dev/null || stat -c%s "$RPM_TARGET" 2>/dev/null) / 1048576}")
            write_success "Downloaded and validated gateway.rpm (${FILE_SIZE_MB} MB)"
        else
            rm -f "$RPM_TARGET"
            write_fail "Downloaded file is not a valid RPM (got HTML error page or wrong file). Check the URL and try again."
        fi
    else
        rm -f "$RPM_TARGET"
        write_fail "Download failed. Check the URL and your network connection."
    fi
else
    # Validate existing RPM file
    if validate_rpm "$RPM_TARGET"; then
        FILE_SIZE_MB=$(awk "BEGIN {printf \"%.1f\", $(stat -f%z "$RPM_TARGET" 2>/dev/null || stat -c%s "$RPM_TARGET" 2>/dev/null) / 1048576}")
        write_success "Validated existing gateway.rpm (${FILE_SIZE_MB} MB)"
    else
        write_fail "Existing gateway.rpm is not a valid RPM file. Please re-download using the URL option."
    fi
fi

# -- Tenant URL ---------------------------------------------------------------
write_step "Qlik Cloud Tenant Configuration"

write_dim "Example: qppqtcenterprise.us.qlikcloud.com"
read -rp "    Enter your Qlik Cloud tenant URL: " TENANT_URL
TENANT_URL=$(echo "$TENANT_URL" | xargs)   # trim whitespace

if [[ -z "$TENANT_URL" ]]; then
    write_warn "No tenant URL entered - using example: qppqtcenterprise.us.qlikcloud.com"
    TENANT_URL="qppqtcenterprise.us.qlikcloud.com"
fi
write_success "Tenant URL set to: $TENANT_URL"

# -- Open Firewall Ports ------------------------------------------------------
write_step "Configuring firewall rules for database ports..."

PORTS=(
    "3306:MySQL"
    "5432:PostgreSQL"
    "1433:MSSQL"
    "22:SSH"
    "3552:Qlik Gateway"
    "8080:Qlik Gateway HTTP"
    "8088:Qlik Gateway"
    "8686:Qlik Gateway"
)

OS_TYPE="$(uname -s)"

if [[ "$OS_TYPE" == "Darwin" ]]; then
    # macOS - Docker Desktop handles port mapping via its VM; no host firewall changes needed
    write_dim "macOS detected. Docker Desktop manages port forwarding through its VM."
    write_dim "No host firewall changes required. If you use a third-party firewall, ensure these ports are allowed:"
    for entry in "${PORTS[@]}"; do
        port="${entry%%:*}"
        name="${entry#*:}"
        write_dim "  Port $port - $name"
    done

elif [[ "$OS_TYPE" == "Linux" ]]; then
    # Linux - try ufw, then firewalld, then warn
    if command -v ufw &>/dev/null; then
        for entry in "${PORTS[@]}"; do
            port="${entry%%:*}"
            name="${entry#*:}"
            if sudo ufw status | grep -qw "$port/tcp"; then
                write_dim "[SKIP] Already open: port $port ($name)"
            else
                if sudo ufw allow "$port/tcp" comment "QlikDMG - $name" &>/dev/null; then
                    write_success "Allowed port $port - $name (ufw)"
                else
                    write_warn "[WARN] Could not open port $port. Run with sudo if firewall access is needed."
                fi
            fi
        done
    elif command -v firewall-cmd &>/dev/null; then
        for entry in "${PORTS[@]}"; do
            port="${entry%%:*}"
            name="${entry#*:}"
            if sudo firewall-cmd --query-port="$port/tcp" &>/dev/null; then
                write_dim "[SKIP] Already open: port $port ($name)"
            else
                if sudo firewall-cmd --permanent --add-port="$port/tcp" &>/dev/null; then
                    write_success "Allowed port $port - $name (firewalld)"
                else
                    write_warn "[WARN] Could not open port $port. Run with sudo if firewall access is needed."
                fi
            fi
        done
        sudo firewall-cmd --reload &>/dev/null || true
    else
        write_warn "No supported firewall manager found (ufw / firewalld)."
        write_warn "Please manually ensure these TCP ports are open:"
        for entry in "${PORTS[@]}"; do
            port="${entry%%:*}"
            name="${entry#*:}"
            write_dim "  Port $port - $name"
        done
    fi
else
    write_warn "Unknown OS ($OS_TYPE). Skipping firewall configuration."
fi

# -- Remove Existing Container ------------------------------------------------
write_step "Checking for existing container named '$CONTAINER_NAME'..."

EXISTING=$(docker ps -aq --filter "name=^${CONTAINER_NAME}$")
if [[ -n "$EXISTING" ]]; then
    write_warn "Found existing container. Stopping and removing..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    write_success "Existing container removed."
else
    write_success "No existing container found."
fi

# -- Build Image --------------------------------------------------------------
write_step "Building Docker image '${IMAGE_NAME}:${IMAGE_TAG}'..."

if ! docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" .; then
    write_fail "Docker build failed. Check the output above for errors."
fi
write_success "Image built successfully."

# -- Create Named Volume ------------------------------------------------------
write_step "Ensuring MySQL data volume '$MYSQL_VOLUME' exists..."

VOLUME_EXISTS=$(docker volume ls --filter "name=^${MYSQL_VOLUME}$" --format "{{.Name}}")
if [[ -z "$VOLUME_EXISTS" ]]; then
    docker volume create "$MYSQL_VOLUME" >/dev/null
    write_success "Volume '$MYSQL_VOLUME' created."
else
    write_success "Volume '$MYSQL_VOLUME' already exists - existing MySQL data will be preserved."
fi

# -- Run Container ------------------------------------------------------------
write_step "Starting container '$CONTAINER_NAME'..."
write_dim "NOTE: --memory=4g is required for SQL Server 2022 to start."

if ! docker run -d \
    --name "$CONTAINER_NAME" \
    --privileged \
    --cgroupns=host \
    --memory=4g \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "${MYSQL_VOLUME}:/var/lib/mysql" \
    -e TENANT_URL="$TENANT_URL" \
    -p 22:22 \
    -p 80:80 \
    -p 443:443 \
    -p 3306:3306 \
    -p 5432:5432 \
    -p 1433:1433 \
    -p 3552:3552 \
    -p 8080:8080 \
    -p 8088:8088 \
    -p 8686:8686 \
    "${IMAGE_NAME}:${IMAGE_TAG}"; then
    write_fail "Failed to start container. Check the output above for errors."
fi
write_success "Container '$CONTAINER_NAME' started successfully."

# -- Status Summary -----------------------------------------------------------
write_step "Deployment complete. Container status:"
docker ps --filter "name=^${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo -e "\033[90m-- Initialization Logs -----------------------------------------------\033[0m"
write_warn "Streaming container initialization logs (Ctrl+C to stop)..."
echo ""
docker exec -it "$CONTAINER_NAME" journalctl -u qlik-dmg-init.service -f || true

echo ""
echo -e "\033[90m-- Connection Details -----------------------------------------------\033[0m"
write_dim "MySQL        : localhost:3306  (root / Qlik1234)"
write_dim "PostgreSQL   : localhost:5432  (postgres / Qlik1234)"
write_dim "SQL Server   : localhost:1433  (sa / Qlik1234!)"
write_dim "Qlik Tenant  : $TENANT_URL"
echo ""
echo -e "\033[90m-- Useful Commands --------------------------------------------------\033[0m"
write_dim "Tail logs:        docker logs -f $CONTAINER_NAME"
write_dim "Open shell:       docker exec -it $CONTAINER_NAME /bin/bash"
write_dim "MSSQL logs:       docker exec -it $CONTAINER_NAME journalctl -u mssql-server -f"
write_dim "Fix repagent:     docker exec -it $CONTAINER_NAME bash -c \"mkdir -p /etc/systemd/system/repagent.service.d && cat > /etc/systemd/system/repagent.service.d/override.conf << 'EOF'
[Service]
PIDFile=
Type=forking
TimeoutStartSec=120
EOF
systemctl daemon-reload && systemctl restart repagent\""
write_dim "Stop container:   docker stop $CONTAINER_NAME"
write_dim "Remove container: docker rm $CONTAINER_NAME"
write_dim "Remove volume:    docker volume rm $MYSQL_VOLUME"
echo -e "\033[90m---------------------------------------------------------------------\033[0m"
echo ""
