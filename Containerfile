FROM rockylinux/rockylinux:10-ubi

ARG MAINTAINER_LABEL="Cody Chapman <cody.chapman@gmail.com>"
LABEL org.opencontainers.image.authors="$MAINTAINER_LABEL" \
      org.opencontainers.image.title="Wordpress Systemd image - Rocky/UBI" \
      org.opencontainers.image.description="Docker image includes mariadb, httpd, php and redis UBI 10 and Rocky Linux repositories."


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
        redis \
        php-pecl-zip \
    && dnf clean all \
    && rm -rf /var/cache/dnf/*

# This container maps to the standard CUPS interface port
EXPOSE 80
RUN systemctl enable httpd && \
    systemctl enable redis 88 \
    systemctl enable mariadb
