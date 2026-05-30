FROM docker.io/library/archlinux:latest

# 1. Update the system and install systemd + basic tools
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm systemd dbus sudo cifs-utils openssh imagemagick fail2ban nano pam && \
    pacman -Scc --noconfirm

# 2. Inform systemd that it is running inside an OCI container
ENV container=podman

# 3. Clean up unnecessary systemd services that cause issues in containers
RUN rm -f /lib/systemd/system/multi-user.target.wants/*; \
    rm -f /etc/systemd/system/*.wants/*; \
    rm -f /lib/systemd/system/local-fs.target.wants/*; \
    rm -f /lib/systemd/system/sockets.target.wants/*udev*; \
    rm -f /lib/systemd/system/sockets.target.wants/*initctl*; \
    rm -f /lib/systemd/system/basic.target.wants/*; \
    rm -f /lib/systemd/system/anaconda.target.wants/*; \
    rm -f /lib/systemd/system/plymouth*; \
    rm -f /lib/systemd/system/systemd-update-utmp*

COPY filesync.* /etc/systemd/system/

COPY usersetup.service /etc/systemd/system/

COPY syncscript.sh /usr/local/bin/syncscript
COPY usersetup.sh /usr/local/bin/usersetup

RUN chmod +x /usr/local/bin/syncscript /usr/local/bin/usersetup

RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#UsePAM yes/UsePAM yes/' /etc/ssh/sshd_config && \
    sed -i 's/systemd//g' /etc/nsswitch.conf && \
    sed -i 's|system-remote-login|system-auth|g' /etc/pam.d/sshd

RUN mkdir -p /run/sshd

# Create necessary runtime directories for PAM and sshd
RUN mkdir -p /run/sshd /run/utmp /var/run/utmp /tmp && \
    chmod 1777 /tmp /run/utmp /var/run/utmp

EXPOSE 22

RUN systemctl enable sshd \
    && systemctl enable filesync.timer \
    && systemctl enable fail2ban \
    && systemctl enable usersetup
