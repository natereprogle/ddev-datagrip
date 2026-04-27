#!/usr/bin/env bash

## #ddev-generated: If you want to edit and own this file, remove this line.

# shellcheck shell=bash
#
# datagrip-lib/versions/2025.2.5.sh
# Configuration generator for DataGrip 2025.2.5 and newer.
#
# Sourced by the main `datagrip` command after all common setup is complete.
# Responsible for building the JDBC URL and writing the DataGrip XML files.
#
# Variables expected from the calling script:
#   DB_TYPE, DATABASE, DDEV_PROJECT, DDEV_TLD, DDEV_HOST_DB_PORT
#   PGPASS (bool string), PGPASS_FILE
#   AUTOREFRESH, uuid_value
#   DATASOURCES_FILE, DATASOURCES_LOCAL_FILE

if [[ "$DB_TYPE" == "mysql" ]]; then
  echo "🔎 Configuring DataGrip for MySQL"
  query="jdbc:mysql://${DDEV_PROJECT}.${DDEV_TLD}:${DDEV_HOST_DB_PORT}/${DATABASE}?user=db&amp;password=db"
  driverRef="mysql.8"
  jdbcDriver="com.mysql.cj.jdbc.Driver"
elif [[ "$DB_TYPE" == "mariadb" ]]; then
  echo "🔎 MariaDB database detected, selecting MariaDB JDBC driver for better compatibility"
  query="jdbc:mariadb://${DDEV_PROJECT}.${DDEV_TLD}:${DDEV_HOST_DB_PORT}/${DATABASE}?user=db&amp;password=db"
  driverRef="mariadb"
  jdbcDriver="org.mariadb.jdbc.Driver"
elif [[ "$DB_TYPE" == "postgres" ]]; then
  echo "🔎 Configuring DataGrip for Postgres"
  if [[ "$PGPASS" == true ]]; then
    query="jdbc:postgresql://${DDEV_PROJECT}.${DDEV_TLD}:${DDEV_HOST_DB_PORT}/${DATABASE}"

    CREDS="${DDEV_PROJECT}.${DDEV_TLD}:${DDEV_HOST_DB_PORT}:${DATABASE}:db:db"
    PATTERN="^.*:[0-9]+:${DATABASE}:db:.*$"

    tmp="$(mktemp "${PGPASS_FILE}.XXXXXX")"

    touch "$PGPASS_FILE"

    awk -v pat="$PATTERN" -v repl="$CREDS" '
      BEGIN { replaced=0 }
      $0 ~ pat { print repl; replaced=1; next }
      { print }
      END { if (!replaced) print repl }
    ' "$PGPASS_FILE" > "$tmp" && mv "$tmp" "$PGPASS_FILE"

    chmod 600 "$PGPASS_FILE"
  else
    query="jdbc:postgresql://${DDEV_PROJECT}.${DDEV_TLD}:${DDEV_HOST_DB_PORT}/${DATABASE}?user=db&amp;password=db"
  fi

  driverRef="postgresql"
  jdbcDriver="org.postgresql.Driver"
else
  echo "❌ Unsupported database type: ${DB_TYPE}"
  return 1
fi

cat > "$DATASOURCES_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
  <component name="DataSourceManagerImpl" format="xml" multifile-model="true">
    <data-source source="LOCAL" name="ddev" uuid="${uuid_value}">
      <driver-ref>${driverRef}</driver-ref>
      <synchronize>true</synchronize>
      <configured-by-url>true</configured-by-url>
      <jdbc-driver>${jdbcDriver}</jdbc-driver>
      <jdbc-url>${query}</jdbc-url>
      <jdbc-additional-properties>
        $(if [[ "${AUTOREFRESH}" != "0" ]]; then echo "<property name=\"auto-refresh-interval\" value=\"${AUTOREFRESH}\" />"; fi)
      </jdbc-additional-properties>
      <driver-properties>
        <property name="autoReconnect" value="true" />
      </driver-properties>
      <working-dir>\$ProjectFileDir\$</working-dir>
    </data-source>
  </component>
</project>
EOF

if [[ "$DB_TYPE" == "postgres" ]]; then
  NODE_BLOCK="<node kind=\"database\" qname=\"@\">
    <node kind=\"schema\" qname=\"@\" />
  </node>
  <node kind=\"database\" qname=\"${DATABASE}\">
    <node kind=\"schema\" qname=\"public\" />
  </node>"
else
  NODE_BLOCK="<node kind=\"schema\">
    <name qname=\"@\" />
    <name qname=\"${DATABASE}\" />
  </node>"
fi

if [[ "$PGPASS" == true ]]; then
  AUTH_BLOCK="<auth-provider>pgpass</auth-provider>
  <user-name>db</user-name>"
else
  AUTH_BLOCK=""
fi

cat > "$DATASOURCES_LOCAL_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
<component name="dataSourceStorageLocal">
  <data-source name="ddev" uuid="${uuid_value}">
    ${AUTH_BLOCK}
    <schema-mapping>
      <introspection-scope>
        ${NODE_BLOCK}
      </introspection-scope>
    </schema-mapping>
    <introspection-level>3</introspection-level>
  </data-source>
</component>
</project>
EOF
