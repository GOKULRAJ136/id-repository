#!/bin/bash
# Creates the mosip_idrepo database for local development.
#
# Runs the repository's own db_scripts/mosip_idrepo scripts (mounted read-only at
# /db_scripts/mosip_idrepo) in the same order as db_scripts/mosip_idrepo/deploy.sh,
# then seeds the salt tables that the id-repository-salt-generator job would
# normally populate.
#
# Executed once by the postgres image on first start (empty data volume). The
# image sources .sh files that are not executable, so everything runs in a
# subshell to keep the entrypoint's shell options and working directory intact.

(
	set -e

	psql_su() {
		psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres "$@"
	}

	cd /db_scripts/mosip_idrepo

	echo "[idrepo-init] creating role idrepouser"
	psql_su -f role_dbuser.sql -v dbuserpwd="'${IDREPO_DB_PASSWORD}'"

	echo "[idrepo-init] creating database mosip_idrepo"
	psql_su -f db.sql

	echo "[idrepo-init] creating tables"
	psql_su -f ddl.sql

	echo "[idrepo-init] granting privileges"
	psql_su -f grants.sql

	echo "[idrepo-init] seeding uin_hash_salt / uin_encrypt_salt"
	psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname mosip_idrepo \
		-f /docker-entrypoint-initdb.d/sql/seed-salts.sql

	echo "[idrepo-init] done"
) || exit 1
