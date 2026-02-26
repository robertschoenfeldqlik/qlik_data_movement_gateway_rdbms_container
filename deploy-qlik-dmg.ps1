# =============================================================================
# Qlik Data Movement Gateway - Docker Deployment Script
# Run this script from the directory containing your Dockerfile
# Usage: .\deploy-qlik-dmg.ps1
# =============================================================================

# -- Configuration -------------------------------------------------------------
$ImageName      = "qlik-dmg"
$ImageTag       = "latest"
$ContainerName  = "qlik-dmg"
$MysqlVolume    = "qlik-mysql-data"
$ScriptDir      = $PSScriptRoot
$RpmFolder      = Join-Path $ScriptDir "rpmfiles"
$RpmTarget      = Join-Path $RpmFolder "gateway.rpm"

# Change to script directory so Docker build context is correct
Set-Location $ScriptDir
Write-Host "==> Working directory: $ScriptDir" -ForegroundColor DarkGray

# -- Helper Functions ----------------------------------------------------------
function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "    ERROR: $Message" -ForegroundColor Red
    exit 1
}

# -- Preflight Checks ----------------------------------------------------------
Write-Step "Running preflight checks..."

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Fail "Docker is not installed or not in PATH. Please install Docker Desktop."
}

docker info > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Docker Desktop is not running. Please start Docker Desktop and try again."
}
Write-Success "Docker is running."

if (-not (Test-Path ".\Dockerfile")) {
    Write-Fail "Dockerfile not found in the current directory: $(Get-Location)"
}
Write-Success "Dockerfile found."

# -- Gateway RPM ---------------------------------------------------------------
Write-Step "Gateway RPM Setup"

if (Test-Path $RpmTarget) {
    $FileSizeMB = [math]::Round((Get-Item $RpmTarget).Length / 1MB, 1)
    Write-Host "    Found existing gateway.rpm ($FileSizeMB MB) in $RpmFolder" -ForegroundColor Yellow
    $useExisting = Read-Host "    Use existing RPM? (Y to keep / N to re-download)"
    if ($useExisting -notmatch "^[Yy]$") {
        $GatewayUrl = Read-Host "    Paste the Gateway RPM download URL"
    }
} else {
    Write-Host "    No gateway.rpm found in $RpmFolder" -ForegroundColor Yellow
    $GatewayUrl = Read-Host "    Paste the Gateway RPM download URL"
}

if ($GatewayUrl) {
    $GatewayUrl = $GatewayUrl.Trim()
    if ($GatewayUrl -eq "") {
        Write-Fail "No URL entered. Cannot build image without gateway.rpm."
    }

    Write-Host "    Downloading from : $GatewayUrl" -ForegroundColor DarkGray
    Write-Host "    Saving to        : $RpmTarget" -ForegroundColor DarkGray

    if (-not (Test-Path $RpmFolder)) {
        New-Item -ItemType Directory -Path $RpmFolder | Out-Null
        Write-Success "Created folder: $RpmFolder"
    }

    try {
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $GatewayUrl -OutFile $RpmTarget -UseBasicParsing
        $ProgressPreference = "Continue"

        if (-not (Test-Path $RpmTarget)) {
            Write-Fail "Download appeared to succeed but file not found at: $RpmTarget"
        }

        # Validate the downloaded file is actually an RPM (starts with RPM magic bytes)
        $bytes = [System.IO.File]::ReadAllBytes($RpmTarget)
        # RPM files start with magic bytes: 0xED 0xAB 0xEE 0xDB
        if ($bytes[0] -eq 0xED -and $bytes[1] -eq 0xAB -and $bytes[2] -eq 0xEE -and $bytes[3] -eq 0xDB) {
            $FileSizeMB = [math]::Round((Get-Item $RpmTarget).Length / 1MB, 1)
            Write-Success "Downloaded and validated gateway.rpm ($FileSizeMB MB)"
        } else {
            Remove-Item $RpmTarget -Force
            Write-Fail "Downloaded file is not a valid RPM (got HTML error page or wrong file). Check the URL and try again."
        }
    } catch {
        Write-Fail "Download failed. Error: $_"
    }
} else {
    # Validate existing RPM file
    $bytes = [System.IO.File]::ReadAllBytes($RpmTarget)
    if ($bytes[0] -eq 0xED -and $bytes[1] -eq 0xAB -and $bytes[2] -eq 0xEE -and $bytes[3] -eq 0xDB) {
        $FileSizeMB = [math]::Round((Get-Item $RpmTarget).Length / 1MB, 1)
        Write-Success "Validated existing gateway.rpm ($FileSizeMB MB)"
    } else {
        Write-Fail "Existing gateway.rpm is not a valid RPM file. Please re-download using the URL option."
    }
}

# -- Tenant URL ----------------------------------------------------------------
Write-Step "Qlik Cloud Tenant Configuration"

Write-Host "    Example: qppqtcenterprise.us.qlikcloud.com" -ForegroundColor DarkGray
$TenantUrl = Read-Host "    Enter your Qlik Cloud tenant URL"
$TenantUrl = $TenantUrl.Trim()

if ($TenantUrl -eq "") {
    Write-Host "    No tenant URL entered - using example: qppqtcenterprise.us.qlikcloud.com" -ForegroundColor Yellow
    $TenantUrl = "qppqtcenterprise.us.qlikcloud.com"
}
Write-Success "Tenant URL set to: $TenantUrl"

# -- Open Firewall Ports -------------------------------------------------------
Write-Step "Configuring Windows Firewall rules for database ports..."

$FirewallPorts = @(
    @{ Port = 3306;  Name = "MySQL" },
    @{ Port = 5432;  Name = "PostgreSQL" },
    @{ Port = 1433;  Name = "MSSQL" },
    @{ Port = 22;    Name = "SSH" },
    @{ Port = 3552;  Name = "Qlik Gateway" },
    @{ Port = 8080;  Name = "Qlik Gateway HTTP" },
    @{ Port = 8088;  Name = "Qlik Gateway" },
    @{ Port = 8686;  Name = "Qlik Gateway" }
)

foreach ($rule in $FirewallPorts) {
    # Inbound rule (database ports reachable from host/Qlik tasks)
    $inboundName = "QlikDMG - $($rule.Name) ($($rule.Port)) Inbound"
    if (Get-NetFirewallRule -DisplayName $inboundName -ErrorAction SilentlyContinue) {
        Write-Host "    [SKIP] Already exists: $inboundName" -ForegroundColor DarkGray
    } else {
        try {
            New-NetFirewallRule `
                -DisplayName $inboundName `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort $rule.Port `
                -Action Allow `
                -Profile Any `
                -ErrorAction Stop | Out-Null
            Write-Success "Inbound  port $($rule.Port) - $($rule.Name)"
        } catch {
            Write-Host "    [WARN] Could not create inbound rule for port $($rule.Port): $_" -ForegroundColor Yellow
        }
    }

    # Outbound rule (gateway ports must reach Qlik Cloud)
    $outboundName = "QlikDMG - $($rule.Name) ($($rule.Port)) Outbound"
    if (Get-NetFirewallRule -DisplayName $outboundName -ErrorAction SilentlyContinue) {
        Write-Host "    [SKIP] Already exists: $outboundName" -ForegroundColor DarkGray
    } else {
        try {
            New-NetFirewallRule `
                -DisplayName $outboundName `
                -Direction Outbound `
                -Protocol TCP `
                -RemotePort $rule.Port `
                -Action Allow `
                -Profile Any `
                -ErrorAction Stop | Out-Null
            Write-Success "Outbound port $($rule.Port) - $($rule.Name)"
        } catch {
            Write-Host "    [WARN] Could not create outbound rule for port $($rule.Port): $_" -ForegroundColor Yellow
            Write-Host "          Re-run as Administrator if firewall access is needed." -ForegroundColor Yellow
        }
    }
}

# -- Remove Existing Container -------------------------------------------------
Write-Step "Checking for existing container named '$ContainerName'..."

$existing = docker ps -aq --filter "name=^${ContainerName}$"
if ($existing) {
    Write-Host "    Found existing container. Stopping and removing..." -ForegroundColor Yellow
    docker stop $ContainerName | Out-Null
    docker rm $ContainerName | Out-Null
    Write-Success "Existing container removed."
} else {
    Write-Success "No existing container found."
}

# -- Build Image ---------------------------------------------------------------
Write-Step "Building Docker image '${ImageName}:${ImageTag}'..."

docker build -t "${ImageName}:${ImageTag}" .

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Docker build failed. Check the output above for errors."
}
Write-Success "Image built successfully."

# -- Create Named Volume -------------------------------------------------------
Write-Step "Ensuring MySQL data volume '$MysqlVolume' exists..."

$volumeExists = docker volume ls --filter "name=^${MysqlVolume}$" --format "{{.Name}}"
if (-not $volumeExists) {
    docker volume create $MysqlVolume | Out-Null
    Write-Success "Volume '$MysqlVolume' created."
} else {
    Write-Success "Volume '$MysqlVolume' already exists - existing MySQL data will be preserved."
}

# -- Run Container -------------------------------------------------------------
Write-Step "Starting container '$ContainerName'..."
Write-Host "    NOTE: --memory=4g is required for SQL Server 2022 to start." -ForegroundColor DarkGray

docker run -d `
    --name $ContainerName `
    --privileged `
    --cgroupns=host `
    --memory=4g `
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw `
    -v ${MysqlVolume}:/var/lib/mysql `
    -e TENANT_URL="$TenantUrl" `
    -p 22:22 `
    -p 80:80 `
    -p 443:443 `
    -p 3306:3306 `
    -p 5432:5432 `
    -p 1433:1433 `
    -p 3552:3552 `
    -p 8080:8080 `
    -p 8088:8088 `
    -p 8686:8686 `
    "${ImageName}:${ImageTag}"

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to start container. Check the output above for errors."
}
Write-Success "Container '$ContainerName' started successfully."

# -- Status Summary ------------------------------------------------------------
Write-Step "Deployment complete. Container status:"
docker ps --filter "name=^${ContainerName}$" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

Write-Host ""
Write-Host "-- Initialization Logs -----------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Streaming container initialization logs (Ctrl+C to stop)..." -ForegroundColor Yellow
Write-Host ""
docker exec -it $ContainerName journalctl -u qlik-dmg-init.service -f

Write-Host ""
Write-Host "-- Connection Details -----------------------------------------------" -ForegroundColor DarkGray
Write-Host "  MySQL        : localhost:3306  (root / Qlik1234)" -ForegroundColor DarkGray
Write-Host "  PostgreSQL   : localhost:5432  (postgres / Qlik1234)" -ForegroundColor DarkGray
Write-Host "  SQL Server   : localhost:1433  (sa / Qlik1234!)" -ForegroundColor DarkGray
Write-Host "  Qlik Tenant  : $TenantUrl" -ForegroundColor DarkGray
Write-Host ""
Write-Host "-- Useful Commands --------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Tail logs:        docker logs -f $ContainerName" -ForegroundColor DarkGray
Write-Host "  Open shell:       docker exec -it $ContainerName /bin/bash" -ForegroundColor DarkGray
Write-Host "  MSSQL logs:       docker exec -it $ContainerName journalctl -u mssql-server -f" -ForegroundColor DarkGray
Write-Host "  Fix repagent:     docker exec -it $ContainerName bash -c `"mkdir -p /etc/systemd/system/repagent.service.d && cat > /etc/systemd/system/repagent.service.d/override.conf << 'EOF'" -ForegroundColor DarkGray
Write-Host "                    [Service]" -ForegroundColor DarkGray
Write-Host "                    PIDFile=" -ForegroundColor DarkGray
Write-Host "                    Type=forking" -ForegroundColor DarkGray
Write-Host "                    TimeoutStartSec=120" -ForegroundColor DarkGray
Write-Host "                    EOF" -ForegroundColor DarkGray
Write-Host "                    systemctl daemon-reload && systemctl restart repagent`"" -ForegroundColor DarkGray
Write-Host "  Stop container:   docker stop $ContainerName" -ForegroundColor DarkGray
Write-Host "  Remove container: docker rm $ContainerName" -ForegroundColor DarkGray
Write-Host "  Remove volume:    docker volume rm $MysqlVolume" -ForegroundColor DarkGray
Write-Host "---------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
