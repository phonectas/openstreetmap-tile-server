#!/bin/bash

set -x

TILESERVER_DATA_PATH=${TILESERVER_DATA_PATH:="/tileserverdata"}
TILESERVER_STORAGE_PATH=${TILESERVER_STORAGE_PATH:="/mnt/azure"}
TILESERVER_DATA_LABEL=${TILESERVER_DATA_LABEL:="data"}
NUMTHREADS=${NUMTHREADS:="1"}

if [ "$TILESERVER_MODE" != "CREATE" ] && [ "$TILESERVER_MODE" != "RESTORE" ]; then
    # Default to CREATE
    TILESERVER_MODE="CREATE"
fi

function createPostgresConfig() {
  cp /etc/postgresql/12/main/postgresql.custom.conf.tmpl /etc/postgresql/12/main/conf.d/postgresql.custom.conf
  sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/12/main/conf.d/postgresql.custom.conf
  cat /etc/postgresql/12/main/conf.d/postgresql.custom.conf
}

function setPostgresPassword() {
    sudo -u postgres psql -c "ALTER USER renderer PASSWORD '${PGPASSWORD:-renderer}'"
}

service apache2 stop

if [ "$TILESERVER_MODE" == "CREATE" ]; then
    # Ensure that database directory is in right state
    chown postgres:postgres -R /var/lib/postgresql
    if [ ! -f /var/lib/postgresql/12/main/PG_VERSION ]; then
        sudo -u postgres /usr/lib/postgresql/12/bin/pg_ctl -D /var/lib/postgresql/12/main/ initdb -o "--locale C.UTF-8"
    fi

    # Initialize PostgreSQL
    createPostgresConfig
    service postgresql start
    sudo -u postgres createuser renderer
    sudo -u postgres createdb -E UTF8 -O renderer gis
    sudo -u postgres psql -d gis -c "CREATE EXTENSION postgis;"
    sudo -u postgres psql -d gis -c "CREATE EXTENSION hstore;"
    sudo -u postgres psql -d gis -c "ALTER TABLE geometry_columns OWNER TO renderer;"
    sudo -u postgres psql -d gis -c "ALTER TABLE spatial_ref_sys OWNER TO renderer;"
    setPostgresPassword

    # Download norway as sample if no data is provided
    if [ ! -f /data.osm.pbf ] && [ -z "$DOWNLOAD_PBF" ]; then
        echo "WARNING: No import file at /data.osm.pbf, so importing norway as example..."
        DOWNLOAD_PBF="https://download.geofabrik.de/europe/norway-latest.osm.pbf"
        DOWNLOAD_POLY="https://download.geofabrik.de/europe/norway.poly"
    fi

    if [ -n "$DOWNLOAD_PBF" ]; then
        echo "INFO: Download PBF file: $DOWNLOAD_PBF"
        wget "$WGET_ARGS" "$DOWNLOAD_PBF" -O /data.osm.pbf
        if [ -n "$DOWNLOAD_POLY" ]; then
            echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
            wget "$WGET_ARGS" "$DOWNLOAD_POLY" -O /data.poly
        fi
    fi

    if [ "$UPDATES" = "enabled" ]; then
        # determine and set osmosis_replication_timestamp (for consecutive updates)
        osmium fileinfo /data.osm.pbf > /var/lib/mod_tile/data.osm.pbf.info
        osmium fileinfo /data.osm.pbf | grep 'osmosis_replication_timestamp=' | cut -b35-44 > /var/lib/mod_tile/replication_timestamp.txt
        REPLICATION_TIMESTAMP=$(cat /var/lib/mod_tile/replication_timestamp.txt)

        # initial setup of osmosis workspace (for consecutive updates)
        sudo -u renderer openstreetmap-tiles-update-expire $REPLICATION_TIMESTAMP
    fi

    # copy polygon file if available
    if [ -f /data.poly ]; then
        sudo -u renderer cp /data.poly /var/lib/mod_tile/data.poly
    fi

    # Import data
    sudo -u renderer osm2pgsql -d gis --flatnodes --create --slim -G --hstore --tag-transform-script /home/renderer/src/openstreetmap-carto/openstreetmap-carto.lua --number-processes ${THREADS:-4} -S /home/renderer/src/openstreetmap-carto/openstreetmap-carto.style /data.osm.pbf ${OSM2PGSQL_EXTRA_ARGS}

    # Create indexes
    sudo -u postgres psql -d gis -f indexes.sql

    # Register that data has changed for mod_tile caching purposes
    touch /var/lib/mod_tile/planet-import-complete

    service postgresql stop

    mkdir $TILESERVER_DATA_PATH

    tar cz /var/lib/postgresql/12/main | split -b 1024MiB - $TILESERVER_DATA_PATH/$TILESERVER_DATA_LABEL.tgz_

    mkdir $TILESERVER_STORAGE_PATH/$TILESERVER_DATA_LABEL

    cp $TILESERVER_DATA_PATH/*.tgz* $TILESERVER_STORAGE_PATH/$TILESERVER_DATA_LABEL

fi

if [ "$TILESERVER_MODE" == "RESTORE" ]; then
    mkdir -p $TILESERVER_DATA_PATH

    cp $TILESERVER_STORAGE_PATH/$TILESERVER_DATA_LABEL/*.tgz* $TILESERVER_DATA_PATH

    # Remove any files present in the target directory
    rm -rf /var/lib/postgresql/12/main/*

    # Extract the archive
    cat $TILESERVER_DATA_PATH/$TILESERVER_DATA_LABEL.tgz_* | tar xz -C /var/lib/postgresql/12/main --strip-components=5

    # Clean /tmp
    rm -rf /tmp/*
fi

# Fix postgres data privileges
chown postgres:postgres /var/lib/postgresql -R

# Configure Apache CORS
if [ "$ALLOW_CORS" == "enabled" ] || [ "$ALLOW_CORS" == "1" ]; then
    echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
fi

# Initialize PostgreSQL and Apache
createPostgresConfig
service postgresql start
service apache2 restart
setPostgresPassword

# Configure renderd threads
sed -i -E "s/num_threads=[0-9]+/num_threads=$NUMTHREADS/g" /usr/local/etc/renderd.conf

# start cron job to trigger consecutive updates
if [ "$UPDATES" = "enabled" ] || [ "$UPDATES" = "1" ]; then
    /etc/init.d/cron start
fi

# Run while handling docker stop's SIGTERM
stop_handler() {
    kill -TERM "$child"
}
trap stop_handler SIGTERM

sudo -u renderer renderd -f -c /usr/local/etc/renderd.conf &
child=$!
wait "$child"

service postgresql stop

exit 0
