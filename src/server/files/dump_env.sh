#!/usr/bin/sh

echo "# lsns - $(date -Iseconds)"
lsns

echo "# /proc/${CLIENT_PID}/ns - $(date -Iseconds)"
ls -l "/proc/${CLIENT_PID}/ns"
