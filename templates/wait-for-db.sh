#!/usr/bin/env bash
# Read environment values as PHP data, never interpolate passwords into PHP code.
set -Eeuo pipefail
for (( attempt=1; attempt<=120; attempt++ )); do
    if php <<'PHP'
<?php
mysqli_report(MYSQLI_REPORT_OFF);
$db = mysqli_init();
$db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 3);
$ok = @$db->real_connect(
    getenv('GLPI_DB_HOST'), getenv('GLPI_DB_USER'), getenv('GLPI_DB_PASSWORD'),
    getenv('GLPI_DB_NAME'), (int) getenv('GLPI_DB_PORT')
);
exit($ok ? 0 : 1);
PHP
    then exit 0; fi
    if (( attempt % 10 == 0 )); then printf 'Waiting for MySQL (%s/120)...\n' "$attempt"; fi
    sleep 1
done
printf '%s\n' 'Database authentication did not become ready.' >&2
exit 1
