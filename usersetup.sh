#!/bin/bash
set -e

USERNAME=$(cat /run/secrets/localuser)
PASSWORD=$(cat /run/secrets/localpassword)

useradd -m -s /bin/bash "$USERNAME" 2>/dev/null || true
echo "$USERNAME:$PASSWORD" | chpasswd
chown "$USERNAME:$USERNAME" "/home/$USERNAME"
