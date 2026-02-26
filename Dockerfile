#
# Qlik Data Movement Gateway - Docker Image
# Base OS: Oracle Linux 9
# Includes:
#   - MySQL Server 8.0     (password: Qlik1234)
#   - PostgreSQL Server 15 (password: Qlik1234)
#   - SQL Server 2022      (password: Qlik1234)  <-- requires special char
#   - Qlik Data Movement Gateway
#
# IMPORTANT: systemd runs as PID 1. Initialization is handled by
#            qlik-dmg-init.service which fires after multi-user.target.
#            Env vars are captured from /proc/1/environ (Docker's PID 1 env)
#
FROM oraclelinux:9

LABEL maintainer="Robert Schoenfeld"

ARG rpmfiles=./rpmfiles
ARG gateway=gateway.rpm

# -----------------------------------------------------------------------------
# Database Credentials (overridable via docker run -e)
# NOTE: MSSQL SA password MUST contain uppercase, lowercase, digit AND
#       a special character or SQL Server will refuse to start.
# -----------------------------------------------------------------------------
ENV MYSQL_ROOT_PASSWORD=Qlik1234
ENV POSTGRES_PASSWORD=Qlik1234
ENV MSSQL_SA_PASSWORD=Qlik1234!
ENV MSSQL_PID=Developer
ENV ACCEPT_EULA=Y
ENV TENANT_URL=qppqtcenterprise.us.qlikcloud.com

# -----------------------------------------------------------------------------
# Step 1: Bootstrap
# -----------------------------------------------------------------------------
RUN yum -y install yum-utils && \
    yum clean all

# -----------------------------------------------------------------------------
# Step 2: Enable Oracle Linux 9 repos
# -----------------------------------------------------------------------------
RUN yum -y install oraclelinux-release-el9 && \
    yum-config-manager --enable ol9_baseos_latest ol9_appstream && \
    yum clean all

# -----------------------------------------------------------------------------
# Step 3: System update and core dependencies
# -----------------------------------------------------------------------------
RUN yum -y update && \
    yum install -y \
        openssh-server \
        openssh-clients \
        sudo \
        initscripts \
        unixODBC \
        curl \
        wget \
        tar \
        libnsl \
        openssl \
        glibc-locale-source \
        glibc-langpack-en \
        file \
    && yum clean all

# -----------------------------------------------------------------------------
# Step 4: Systemd - install and strip unnecessary units
# -----------------------------------------------------------------------------
RUN yum -y install systemd systemd-sysv && \
    yum clean all && \
    (cd /lib/systemd/system/sysinit.target.wants/; \
        for i in *; do [ $i == systemd-tmpfiles-setup.service ] || rm -f $i; done) && \
    rm -f /lib/systemd/system/multi-user.target.wants/* && \
    rm -f /etc/systemd/system/*.wants/* && \
    rm -f /lib/systemd/system/local-fs.target.wants/* && \
    rm -f /lib/systemd/system/sockets.target.wants/*udev* && \
    rm -f /lib/systemd/system/sockets.target.wants/*initctl* && \
    rm -f /lib/systemd/system/basic.target.wants/* && \
    rm -f /lib/systemd/system/anaconda.target.wants/*

# -----------------------------------------------------------------------------
# Step 5: Create SSH user
# -----------------------------------------------------------------------------
RUN useradd -m qlikdmg && \
    echo 'qlikdmg:Qlik1234' | chpasswd

RUN ssh-keygen -A

# -----------------------------------------------------------------------------
# Step 6: MySQL Server 8.0 + ODBC Driver
# -----------------------------------------------------------------------------
RUN yum install -y \
        https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm && \
    yum clean all

RUN yum install -y --nogpgcheck \
        mysql-server \
        mysql-connector-odbc \
    && yum clean all

RUN mkdir -p /etc/mysql/conf.d && \
    mkdir -p /docker-entrypoint-initdb.d

COPY custom.cnf /etc/mysql/conf.d/custom.cnf
COPY churn-dump.sql /docker-entrypoint-initdb.d/churn-dump.sql

# -----------------------------------------------------------------------------
# Step 7: PostgreSQL 15 Server + ODBC Driver
# -----------------------------------------------------------------------------
RUN yum install -y \
        https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm && \
    yum clean all

RUN yum install -y \
        postgresql15-server \
        postgresql15 \
        postgresql-odbc \
    && yum clean all

# -----------------------------------------------------------------------------
# Step 8: SQL Server 2022 + ODBC Driver
# -----------------------------------------------------------------------------
RUN curl -fsSL https://packages.microsoft.com/config/rhel/9/mssql-server-2022.repo \
        -o /etc/yum.repos.d/mssql-server.repo && \
    curl -fsSL https://packages.microsoft.com/config/rhel/9/prod.repo \
        -o /etc/yum.repos.d/mssql-release.repo && \
    yum install -y mssql-server && \
    ACCEPT_EULA=Y yum install -y msodbcsql18 mssql-tools18 && \
    yum clean all

ENV PATH="/opt/mssql-tools18/bin:$PATH"

# -----------------------------------------------------------------------------
# Step 9: Qlik Data Movement Gateway RPM
# -----------------------------------------------------------------------------
COPY $rpmfiles/$gateway /tmp/gateway.rpm

# -----------------------------------------------------------------------------
# Step 10: Environment capture + systemd services
# Reads from /proc/1/environ (Docker's PID 1 env) so -e vars reach services
# -----------------------------------------------------------------------------
RUN cat > /usr/local/bin/dump-env.sh << 'SCRIPT'
#!/bin/bash
cat /proc/1/environ | tr '\0' '\n' | \
    grep -E "^(TENANT_URL|MYSQL_ROOT_PASSWORD|POSTGRES_PASSWORD|MSSQL_SA_PASSWORD|MSSQL_PID|ACCEPT_EULA)=" \
    > /etc/qlik-dmg.env
chmod 600 /etc/qlik-dmg.env
SCRIPT
RUN chmod +x /usr/local/bin/dump-env.sh

RUN cat > /etc/systemd/system/qlik-dmg-env.service << 'EOF'
[Unit]
Description=Capture Docker environment variables for Qlik DMG
DefaultDependencies=no
Before=qlik-dmg-init.service
After=systemd-remount-fs.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/dump-env.sh

[Install]
WantedBy=multi-user.target
EOF

COPY qlik-dmg-init.service /etc/systemd/system/qlik-dmg-init.service

RUN systemctl enable qlik-dmg-env.service && \
    systemctl enable qlik-dmg-init.service

# -----------------------------------------------------------------------------
# Entrypoint script
# -----------------------------------------------------------------------------
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# -----------------------------------------------------------------------------
# Environment Variables
# -----------------------------------------------------------------------------
ENV PATH="/opt/qlik/gateway/movement/bin:/opt/qlik/gateway/bin:$PATH"
ENV LD_LIBRARY_PATH="/opt/qlik/gateway/lib:/usr/lib64"

# -----------------------------------------------------------------------------
# Exposed Ports
# 22    - SSH          3306 - MySQL
# 80    - HTTP         5432 - PostgreSQL
# 443   - HTTPS        1433 - MSSQL
# 3552  - Qlik Gateway
# 8080  - Qlik Gateway HTTP
# 8088  - Qlik Gateway
# 8686  - Qlik Gateway
# -----------------------------------------------------------------------------
EXPOSE 22 80 443 3306 5432 1433 3552 8080 8088 8686

# -----------------------------------------------------------------------------
# Systemd is PID 1 - initialization handled by qlik-dmg-init.service
# -----------------------------------------------------------------------------
CMD ["/usr/sbin/init"]
