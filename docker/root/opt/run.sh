#!/usr/bin/env sh
set -e

exec </dev/null
exec 2>&1

echo "net.core.somaxconn is: $(cat /proc/sys/net/core/somaxconn)"

if [ $# -eq 0 ]; then
  /sbin/runsvdir -P /etc/service
fi

/sbin/runsvdir -P /etc/service &
