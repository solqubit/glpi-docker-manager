#!/usr/bin/env bash
# Runs only on the official MySQL image's empty-directory initialization.
# It may be sourced OR executed, depending on the host mount's executable bit.
# Passwords stay in the container environment/stdin, never process arguments.
gdm_create_application_user() {
    local gdm_password gdm_database
    gdm_password=${GDM_DB_PASSWORD:?}
    gdm_password=${gdm_password//\'/\'\'}
    gdm_database=${MYSQL_DATABASE:?}
    gdm_database=${gdm_database//_/\\_}
    MYSQL_PWD=${MYSQL_ROOT_PASSWORD:?} mysql --protocol=SOCKET -uroot <<SQL
SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES';
CREATE USER '${GDM_DB_USER:?}'@'%' IDENTIFIED BY '${gdm_password}';
GRANT ALL PRIVILEGES ON \`${gdm_database}\`.* TO '${GDM_DB_USER}'@'%';
SQL
}
if ! gdm_create_application_user; then exit 1; fi
unset -f gdm_create_application_user
