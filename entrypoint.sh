#!/bin/bash
#
# Qlik Data Movement Gateway - Initialization Script
# Runs as a oneshot systemd service (qlik-dmg-init.service)
# Systemd is PID 1 - env vars sourced from /etc/qlik-dmg.env
#

# Source env vars captured from Docker's runtime environment
if [ -f /etc/qlik-dmg.env ]; then
    source /etc/qlik-dmg.env
    echo "==> [Init] Environment loaded from /etc/qlik-dmg.env"
else
    echo "==> [Init] WARNING: /etc/qlik-dmg.env not found - using image defaults"
fi

# Apply defaults if any vars are still empty
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-Qlik1234}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-Qlik1234}"
MSSQL_SA_PASSWORD="${MSSQL_SA_PASSWORD:-Qlik1234}"
MSSQL_PID="${MSSQL_PID:-Developer}"
TENANT_URL="${TENANT_URL:-qppqtcenterprise.us.qlikcloud.com}"

echo "==> [Init] Qlik DMG initialization starting..."
echo "    Tenant URL : ${TENANT_URL}"

# =============================================================================
# MySQL 8.0 Initialization
# =============================================================================
echo ""

if [ -d "/var/lib/mysql/mysql" ]; then
    echo "==> [MySQL] Data directory already initialized - skipping init."
    MYSQL_ALREADY_INITIALIZED=true
else
    echo "==> [MySQL] Initializing data directory..."
    mysqld --initialize-insecure --user=mysql
    MYSQL_ALREADY_INITIALIZED=false
fi

echo "==> [MySQL] Starting service..."
systemctl start mysqld
systemctl enable mysqld

echo "==> [MySQL] Waiting for service to be ready..."
until mysqladmin ping --silent 2>/dev/null; do
    echo "    Waiting..."; sleep 2
done

if [ "$MYSQL_ALREADY_INITIALIZED" = "false" ]; then
    echo "==> [MySQL] Setting root password..."
    mysql -u root --connect-expired-password --protocol=socket \
        -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';"
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" --protocol=socket \
        -e "FLUSH PRIVILEGES;"
    echo "    Root password set."

    echo "==> [MySQL] Restarting to apply custom.cnf (binlog/CDC settings)..."
    systemctl restart mysqld
    until mysqladmin -u root -p"${MYSQL_ROOT_PASSWORD}" ping --silent 2>/dev/null; do
        sleep 2
    done

    echo "==> [MySQL] Granting remote root access (required for gateway)..."
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" --protocol=socket         -e "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';"
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" --protocol=socket         -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" --protocol=socket         -e "FLUSH PRIVILEGES;"
    echo "    Remote root access granted."

    echo "==> [MySQL] Loading churn demo dataset..."
    mysql -u root -p"${MYSQL_ROOT_PASSWORD}" --protocol=socket \
        < /docker-entrypoint-initdb.d/churn-dump.sql
    echo "    Churn dataset loaded."
else
    echo "==> [MySQL] Skipping password set and data load - already configured."
fi

# =============================================================================
# PostgreSQL 15 Initialization
# =============================================================================
echo ""

if [ -f "/var/lib/pgsql/15/data/PG_VERSION" ]; then
    echo "==> [PostgreSQL] Already initialized - skipping init."
    POSTGRES_ALREADY_INITIALIZED=true
else
    echo "==> [PostgreSQL] Initializing database cluster..."
    /usr/pgsql-15/bin/postgresql-15-setup initdb
    POSTGRES_ALREADY_INITIALIZED=false
fi

echo "==> [PostgreSQL] Starting service..."
systemctl start postgresql-15
systemctl enable postgresql-15

echo "==> [PostgreSQL] Waiting for service to be ready..."
until /usr/pgsql-15/bin/pg_isready -q -h /var/run/postgresql 2>/dev/null; do
    echo "    Waiting..."; sleep 2
done

if [ "$POSTGRES_ALREADY_INITIALIZED" = "false" ]; then
    echo "==> [PostgreSQL] Setting postgres superuser password..."
    runuser -u postgres -- /usr/pgsql-15/bin/psql -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_PASSWORD}';"
    echo "    Postgres password set."

    echo "==> [PostgreSQL] Enabling remote connections..."
    PG_HBA="/var/lib/pgsql/15/data/pg_hba.conf"
    PG_CONF="/var/lib/pgsql/15/data/postgresql.conf"
    echo "host    all             all             0.0.0.0/0               md5" >> "$PG_HBA"
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
    systemctl restart postgresql-15
    echo "    Remote connections enabled."
else
    echo "==> [PostgreSQL] Skipping password set - already configured."
fi

# =============================================================================
# SQL Server 2022 Initialization
# =============================================================================
echo ""

# Check if MSSQL was fully set up by verifying the system databases exist
# mssql.conf alone is not sufficient - setup may have failed previously
if [ -f "/var/opt/mssql/data/master.mdf" ]; then
    echo "==> [MSSQL] Already initialized - skipping setup."
else
    echo "==> [MSSQL] Running initial setup..."
    # NOTE: SQL Server complexity requirements (upper+lower+digit+special) are
    # bypassed here by pre-seeding mssql.conf before setup runs.
    ACCEPT_EULA=Y MSSQL_SA_PASSWORD="${MSSQL_SA_PASSWORD}" MSSQL_PID="${MSSQL_PID}" \
        /opt/mssql/bin/mssql-conf -n setup accept-eula
    echo "    MSSQL setup complete."
fi

echo "==> [MSSQL] Starting service..."
systemctl start mssql-server
systemctl enable mssql-server

echo "==> [MSSQL] Waiting for service to be ready (up to 90s - this is normal for first boot)..."
MSSQL_RETRIES=0
until /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "${MSSQL_SA_PASSWORD}" \
    -Q "SELECT @@VERSION" -C -l 5 > /dev/null 2>&1; do
    echo "    Waiting..."; sleep 3
    MSSQL_RETRIES=$((MSSQL_RETRIES + 1))
    if [ $MSSQL_RETRIES -ge 30 ]; then
        echo "    ERROR: MSSQL did not become ready after 90s."
        echo "    Check logs: journalctl -u mssql-server"
        break
    fi
done
echo "    SQL Server is ready."

# =============================================================================
# Qlik Data Movement Gateway Installation
# =============================================================================
echo ""

if [ -f "/tmp/gateway.rpm" ]; then
    # Verify it is actually an RPM before attempting install
    if file /tmp/gateway.rpm | grep -q "RPM"; then
        echo "==> [Gateway] Installing Qlik Data Movement Gateway..."
        QLIK_CUSTOMER_AGREEMENT_ACCEPT=yes rpm -ivh /tmp/gateway.rpm
        rm -f /tmp/gateway.rpm
    else
        echo "==> [Gateway] ERROR: /tmp/gateway.rpm is not a valid RPM file."
        echo "    File type: $(file /tmp/gateway.rpm)"
        echo "    Please re-download a valid gateway RPM and rebuild the image."
        rm -f /tmp/gateway.rpm
    fi
else
    echo "==> [Gateway] Gateway already installed - skipping."
fi

if [ -d "/opt/qlik/gateway/movement/bin" ]; then
    echo "==> [Gateway] Setting tenant URL: ${TENANT_URL}..."
    cd /opt/qlik/gateway/movement/bin/
    ./agentctl qcs set_config --tenant_url "${TENANT_URL}"

    echo ""
    echo "==> [Drivers] Installing MySQL, Snowflake, and MSSQL drivers..."
    echo "    (License agreements auto-accepted via ACCEPT_EULA=Y)"
    cd /opt/qlik/gateway/movement/drivers/bin/
    ACCEPT_EULA=Y ./install mysql    > /dev/null 2>&1 && echo "    [OK] MySQL driver installed"    || echo "    [WARN] MySQL driver install returned non-zero"
    ACCEPT_EULA=Y ./install snowflake > /dev/null 2>&1 && echo "    [OK] Snowflake driver installed" || echo "    [WARN] Snowflake driver install returned non-zero"
    ACCEPT_EULA=Y ./install mssql    > /dev/null 2>&1 && echo "    [OK] MSSQL driver installed"    || echo "    [WARN] MSSQL driver install returned non-zero"

    echo ""
    echo "==> [repagent] Applying systemd override (Type=forking, TimeoutStartSec=120)..."
    mkdir -p /etc/systemd/system/repagent.service.d
    cat > /etc/systemd/system/repagent.service.d/override.conf << 'OVERRIDE'
[Service]
PIDFile=
Type=forking
TimeoutStartSec=120
OVERRIDE
    systemctl daemon-reload

    echo "==> [repagent] Starting service..."
    cd /opt/qlik/gateway/movement/bin/
    systemctl start repagent
    systemctl enable repagent
    systemctl status repagent --no-pager

    echo ""
    echo "==> [Gateway] Waiting for repagent to be ready..."
    REPAGENT_RETRIES=0
    until systemctl is-active --quiet repagent; do
        sleep 2
        REPAGENT_RETRIES=$((REPAGENT_RETRIES + 1))
        if [ $REPAGENT_RETRIES -ge 15 ]; then
            echo "    WARNING: repagent did not become active after 30s"
            break
        fi
    done

    echo "==> [Gateway] Retrieving registration token..."
    REGISTRATION_JSON=$(./agentctl qcs get_registration 2>&1)
    REGISTRATION_EXIT=$?
else
    echo "==> [Gateway] WARNING: Gateway not installed - skipping agentctl and driver steps."
fi

# =============================================================================
# Startup Summary
# =============================================================================
echo ""
echo "=========================================================="
echo "  Qlik DMG Container Ready"
echo "=========================================================="
echo ""
echo "  MySQL 8.0"
echo "    Host     : localhost:3306"
echo "    User     : root"
echo "    Password : ${MYSQL_ROOT_PASSWORD}"
echo ""
echo "  PostgreSQL 15"
echo "    Host     : localhost:5432"
echo "    User     : postgres"
echo "    Password : ${POSTGRES_PASSWORD}"
echo ""
echo "  SQL Server 2022"
echo "    Host     : localhost:1433"
echo "    User     : sa"
echo "    Password : ${MSSQL_SA_PASSWORD}"
echo ""
echo "  Qlik Gateway Tenant : ${TENANT_URL}"
echo ""
echo "  Gateway Registration Token :"
if [ -n "$REGISTRATION_JSON" ]; then
    echo "$REGISTRATION_JSON"
else
    echo "  (not available - run: cd /opt/qlik/gateway/movement/bin && ./agentctl qcs get_registration)"
fi
echo ""
echo "=========================================================="
