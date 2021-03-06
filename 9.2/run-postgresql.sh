#!/bin/bash

set -eu

# Data dir
if [ -O $HOME/data ]; then
  export PGDATA=$HOME/data
else
  # If current user does not own data directory
  # create a subdirectory that the user does own
  if [ ! -d $HOME/data/userdata ]; then
    mkdir $HOME/data/userdata
  fi
  export PGDATA=$HOME/data/userdata
fi
POSTGRESQL_CONFIG_FILE=$HOME/openshift-custom-postgresql.conf

# Configuration settings.
export POSTGRESQL_MAX_CONNECTIONS=${POSTGRESQL_MAX_CONNECTIONS:-100}
export POSTGRESQL_SHARED_BUFFERS=${POSTGRESQL_SHARED_BUFFERS:-32MB}

# Be paranoid and stricter than we should be.
psql_identifier_regex='^[a-zA-Z_][a-zA-Z0-9_]*$'
psql_password_regex='^[a-zA-Z0-9_~!@#$%^&*()-=<>,.?;:|]+$'

function usage() {
  if [ $# == 2 ]; then
    echo "error: $1"
  fi
  echo "You must specify following environment variables:"
  echo "  POSTGRESQL_USER (regex: '$psql_identifier_regex')"
  echo "  POSTGRESQL_PASSWORD (regex: '$psql_password_regex')"
  echo "  POSTGRESQL_DATABASE (regex: '$psql_identifier_regex')"
  echo "Optional:"
  echo "  POSTGRESQL_ADMIN_PASSWORD (regex: '$psql_password_regex')"
  echo "Settings:"
  echo "  POSTGRESQL_MAX_CONNECTIONS (default: 100)"
  echo "  POSTGRESQL_SHARED_BUFFERS (default: 32MB)"
  exit 1
}

function check_env_vars() {
  if ! [[ -v POSTGRESQL_USER && -v POSTGRESQL_PASSWORD && -v POSTGRESQL_DATABASE ]]; then
    usage
  fi

  [[ "$POSTGRESQL_USER"     =~ $psql_identifier_regex ]] || usage
  [ ${#POSTGRESQL_USER} -le 63 ] || usage "PostgreSQL username too long (maximum 63 characters)"
  [[ "$POSTGRESQL_PASSWORD" =~ $psql_password_regex   ]] || usage
  [[ "$POSTGRESQL_DATABASE" =~ $psql_identifier_regex ]] || usage
  [ ${#POSTGRESQL_DATABASE} -le 63 ] || usage "Database name too long (maximum 63 characters)"
  if [ -v POSTGRESQL_ADMIN_PASSWORD ]; then
    [[ "$POSTGRESQL_ADMIN_PASSWORD" =~ $psql_password_regex ]] || usage
  fi
}

# Make sure env variables don't propagate to PostgreSQL process.
function unset_env_vars() {
  unset POSTGRESQL_USER
  unset POSTGRESQL_PASSWORD
  unset POSTGRESQL_DATABASE
  unset POSTGRESQL_ADMIN_PASSWORD
}

function initialize_database() {
  check_env_vars

  # Initialize the database cluster with utf8 support enabled by default.
  # This might affect performance, see:
  # http://www.postgresql.org/docs/9.2/static/locale.html
  LANG=${LANG:-en_US.utf8} initdb

  # PostgreSQL configuration.
  cat >> "$PGDATA/postgresql.conf" <<EOF

# Custom OpenShift configuration:
include '${POSTGRESQL_CONFIG_FILE}'
EOF

  # Access control configuration.
  cat >> "$PGDATA/pg_hba.conf" <<EOF

#
# Custom OpenShift configuration starting at this point.
#

# Allow connections from all hosts.
host all all all md5
EOF

  pg_ctl -w start
  createuser "$POSTGRESQL_USER"
  createdb --owner="$POSTGRESQL_USER" "$POSTGRESQL_DATABASE"
  psql --command "ALTER USER \"${POSTGRESQL_USER}\" WITH ENCRYPTED PASSWORD '${POSTGRESQL_PASSWORD}';"

  if [ -v POSTGRESQL_ADMIN_PASSWORD ]; then
    psql --command "ALTER USER \"postgres\" WITH ENCRYPTED PASSWORD '${POSTGRESQL_ADMIN_PASSWORD}';"
  fi

  pg_ctl stop
}

# New config is generated every time a container is created. It only contains
# additional custom settings and is included from $PGDATA/postgresql.conf.
envsubst < ${POSTGRESQL_CONFIG_FILE}.template > ${POSTGRESQL_CONFIG_FILE}

# Generate passwd file based on current uid
export USER_ID=$(id -u)
envsubst < ${HOME}/passwd.template > ${HOME}/passwd
export LD_PRELOAD=libnss_wrapper.so
export NSS_WRAPPER_PASSWD=/var/lib/pgsql/passwd
export NSS_WRAPPER_GROUP=/etc/group

if [ "$1" = "postgres" -a ! -f "$PGDATA/postgresql.conf" ]; then
  initialize_database
fi

unset_env_vars
exec "$@"
