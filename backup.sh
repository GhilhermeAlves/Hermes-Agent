#!/bin/bash
# Backup diario do Hermes
cd /opt/hermes/app || exit 1
trap 'docker compose start gateway' EXIT
docker compose stop gateway
D=/opt/hermes/backups
F=$D/data-$(date +%F).tar.gz
tar czf "$F" -C /opt/hermes data
chmod 600 "$F"
find "$D" -name 'data-*.tar.gz' -mtime +14 -delete
echo "$(date) backup ok: $F"
