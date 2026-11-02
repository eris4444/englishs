#!/usr/bin/env bash
# Embeds helper.py and templates/ at the end of install.sh, so install.sh is a single file
# that needs no other downloads. Run after changing helper.py or a template:
#   bash build.sh          rebuild
#   bash build.sh --check  fail if install.sh is out of date
set -euo pipefail
cd "$(dirname "$0")"
mark=__XRAY_SITE_PAYLOAD__
payload() {
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=2026-01-01 -cf - helper.py templates |
        gzip -9n | base64 -w 76
}
head_part="$(sed "/^$mark\$/,\$d" install.sh)"
new="$(printf '%s\n%s\n' "$head_part" "$mark"; payload)"
if [ "${1:-}" = --check ]; then
    [ "$new" = "$(cat install.sh)" ] || { echo "install.sh is out of date: run bash build.sh" >&2; exit 1; }
    echo "install.sh is up to date."
    exit 0
fi
printf '%s\n' "$new" > install.sh.new
chmod 755 install.sh.new
mv install.sh.new install.sh
echo "install.sh: $(wc -c < install.sh) bytes, payload $(payload | wc -c) bytes"
