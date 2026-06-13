FROM rockylinux/rockylinux:10-ubi

ARG MAINTAINER_LABEL="Cody Chapman <cody.chapman@gmail.com>"
LABEL org.opencontainers.image.authors="$MAINTAINER_LABEL" \
      org.opencontainers.image.title="Wordpress Systemd image - Rocky/UBI" \
      org.opencontainers.image.description="Docker image includes mariadb, httpd, php and redis UBI 10 and Rocky Linux repositories."

ENV TZ=America/Chicago
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# 2. Install fundamental tools, CUPS, and available printer drivers/backends
# Note: RHEL/Rocky packages combine many individual printer drivers into comprehensive suites 
# (e.g., cups-filters, foomatic-db-ppds, and gutenprint).
RUN dnf update -y && \
    dnf install -y \
        sudo \
        util-linux \
        httpd \
        mariadb-server \
        mariadb \
        php \
        php-mysqlnd \
        php-gd \
        php-xml \
        php-mbstring \
        php-json \
        php-intl \
        php-pecl-zip \
        php-ldap \
        valkey \
        procps-ng \
    && dnf clean all \
    && rm -rf /var/cache/dnf/*

COPY usersetup.sh /usr/local/bin/usersetup
COPY usersetup.service /etc/systemd/system
RUN chmod +x /usr/local/bin/usersetup
RUN sudo sed -i 's/#bind-address=0.0.0.0/bind-address=0.0.0.0/' /etc/my.cnf.d/mariadb-server.cnf

# This container maps to the standard CUPS interface port
EXPOSE 80 3306
RUN systemctl enable httpd && \
    systemctl enable valkey && \
    systemctl enable mariadb && \
    systemctl enable usersetup
