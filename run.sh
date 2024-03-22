#!/bin/bash

set -euo pipefail

function createPostgresConfig() {
  cp /etc/postgresql/$PG_VERSION/main/postgresql.custom.conf.tmpl /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
  sudo -u postgres echo "autovacuum = $AUTOVACUUM" >> /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
  cat /etc/postgresql/$PG_VERSION/main/conf.d/postgresql.custom.conf
}

function setPostgresPassword() {
    sudo -u postgres psql -c "ALTER USER renderer PASSWORD '${PGPASSWORD:-renderer}'"
}

set -x

TILESERVER_DATA_PATH=${TILESERVER_DATA_PATH:="/tileserverdata"}
TILESERVER_STORAGE_PATH=${TILESERVER_STORAGE_PATH:="/mnt/azure"}
TILESERVER_DATA_LABEL=${TILESERVER_DATA_LABEL:="data"}
TILESERVER_PRERENDER=${TILESERVER_PRERENDER:="0"}

if [ "$TILESERVER_MODE" != "CREATE" ] && [ "$TILESERVER_MODE" != "RESTORE" ] && [ "$TILESERVER_MODE" != "CREATESCP" ] && [ "$TILESERVER_MODE" != "RESTORESCP" ]; then
    # Default to CREATE
    TILESERVER_MODE="RESTORESCP"
fi

# if there is no custom style mounted, then use osm-carto
if [ ! "$(ls -A /data/style/)" ]; then
    mv /home/renderer/src/openstreetmap-carto-backup/* /data/style/
fi

# carto build
if [ ! -f /data/style/mapnik.xml ]; then
    cd /data/style/
    carto ${NAME_MML:-project.mml} > mapnik.xml
fi

service apache2 stop

if [ "$TILESERVER_MODE" == "CREATE" ] || [ "$TILESERVER_MODE" == "CREATESCP" ]; then
    # Ensure that database directory is in right state
    mkdir -p /data/database/postgres/
    chown renderer: /data/database/
    chown -R postgres: /var/lib/postgresql /data/database/postgres/
    if [ ! -f /data/database/postgres/PG_VERSION ]; then
        sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/pg_ctl -D /data/database/postgres/ initdb -o "--locale C.UTF-8"
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
    if [ ! -f /data/region.osm.pbf ] && [ -z "${DOWNLOAD_PBF:-}" ]; then
        echo "WARNING: No import file at /data/region.osm.pbf, so importing norway as example..."
        DOWNLOAD_PBF="https://download.geofabrik.de/europe/norway-latest.osm.pbf"
        DOWNLOAD_POLY="https://download.geofabrik.de/europe/norway.poly"
    fi

    if [ -n "${DOWNLOAD_PBF:-}" ]; then
        echo "INFO: Download PBF file: $DOWNLOAD_PBF"
        wget ${WGET_ARGS:-} "$DOWNLOAD_PBF" -O /data/region.osm.pbf
        if [ -n "${DOWNLOAD_POLY:-}" ]; then
            echo "INFO: Download PBF-POLY file: $DOWNLOAD_POLY"
            wget ${WGET_ARGS:-} "$DOWNLOAD_POLY" -O /data/region.poly
        fi
    fi

    if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
        # determine and set osmosis_replication_timestamp (for consecutive updates)
        REPLICATION_TIMESTAMP=`osmium fileinfo -g header.option.osmosis_replication_timestamp /data/region.osm.pbf`

        # initial setup of osmosis workspace (for consecutive updates)
        sudo -E -u renderer openstreetmap-tiles-update-expire.sh $REPLICATION_TIMESTAMP
    fi

    # copy polygon file if available
    if [ -f /data/region.poly ]; then
        cp /data/region.poly /data/database/region.poly
        chown renderer: /data/database/region.poly
    fi

    # flat-nodes
    if [ "${FLAT_NODES:-}" == "enabled" ] || [ "${FLAT_NODES:-}" == "1" ]; then
        OSM2PGSQL_EXTRA_ARGS="${OSM2PGSQL_EXTRA_ARGS:-} --flat-nodes /data/database/flat_nodes.bin"
    fi

    # Import data
    sudo -u renderer osm2pgsql -d gis --create --slim -G --hstore  \
      --tag-transform-script /data/style/${NAME_LUA:-openstreetmap-carto.lua}  \
      --number-processes ${THREADS:-4}  \
      -S /data/style/${NAME_STYLE:-openstreetmap-carto.style}  \
      /data/region.osm.pbf  \
      ${OSM2PGSQL_EXTRA_ARGS:-}  \
    ;

    # old flat-nodes dir
    if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
        mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
        chown renderer: /data/database/flat_nodes.bin
    fi

    # Create indexes
    if [ -f /data/style/${NAME_SQL:-indexes.sql} ]; then
        sudo -u postgres psql -d gis -f /data/style/${NAME_SQL:-indexes.sql}
    fi

    #Import external data
    chown -R renderer: /home/renderer/src/ /data/style/
    if [ -f /data/style/scripts/get-external-data.py ] && [ -f /data/style/external-data.yml ]; then
        sudo -E -u renderer python3 /data/style/scripts/get-external-data.py -c /data/style/external-data.yml -D /data/style/data
    fi

    # Register that data has changed for mod_tile caching purposes
    sudo -u renderer touch /data/database/planet-import-complete

    service postgresql stop

    mkdir $TILESERVER_DATA_PATH

    tar cz /data/database | split -b 1024MiB - $TILESERVER_DATA_PATH/$TILESERVER_DATA_LABEL.tgz_

    if [ "$TILESERVER_MODE" == "CREATESCP" ]; then
        mkdir $TILESERVER_DATA_LABEL
        scp -i /scpkey/scpkey -r -o StrictHostKeyChecking=no $TILESERVER_DATA_LABEL $TILESERVER_STORAGE_PATH/
        scp -i /scpkey/scpkey -o StrictHostKeyChecking=no $TILESERVER_DATA_PATH/*.tgz* $TILESERVER_STORAGE_PATH/$TILESERVER_DATA_LABEL
    else
        mkdir $TILESERVER_STORAGE_PATH/$TILESERVER_DATA_LABEL
        cp $TILESERVER_DATA_PATH/*.tgz* $TILESERVER_STORAGE_PATH/$TILESERVER_DATA_LABEL
    fi

    exit 0
fi

if [ "$TILESERVER_MODE" == "RESTORE" ] || [ "$TILESERVER_MODE" == "RESTORESCP" ]; then
    # Clean /tmp
    rm -rf /tmp/*

    mkdir -p $TILESERVER_DATA_PATH

    if [ ! -f /data/database/restored ]; then
        if [ "$TILESERVER_MODE" == "RESTORESCP" ]; then
            scp -i /scpkey/scpkey -o StrictHostKeyChecking=no $TILESERVER_STORAGE_PATH/$TILESERVER_DATA_LABEL/*.tgz* $TILESERVER_DATA_PATH
        else
            cp $TILESERVER_STORAGE_PATH/$TILESERVER_DATA_LABEL/*.tgz*  $TILESERVER_DATA_PATH
        fi

        cat $TILESERVER_DATA_PATH/$TILESERVER_DATA_LABEL.tgz_* | tar xz -C /data/database --strip-components=2

        rm -rf $TILESERVER_DATA_PATH

        touch /data/database/restored

        # migrate old files
        if [ -f /data/database/PG_VERSION ] && ! [ -d /data/database/postgres/ ]; then
            mkdir /data/database/postgres/
            mv /data/database/* /data/database/postgres/
        fi
        if [ -f /nodes/flat_nodes.bin ] && ! [ -f /data/database/flat_nodes.bin ]; then
            mv /nodes/flat_nodes.bin /data/database/flat_nodes.bin
        fi
        if [ -f /data/tiles/data.poly ] && ! [ -f /data/database/region.poly ]; then
            mv /data/tiles/data.poly /data/database/region.poly
        fi

        # sync planet-import-complete file
        if [ -f /data/tiles/planet-import-complete ] && ! [ -f /data/database/planet-import-complete ]; then
            cp /data/tiles/planet-import-complete /data/database/planet-import-complete
        fi
        if ! [ -f /data/tiles/planet-import-complete ] && [ -f /data/database/planet-import-complete ]; then
            cp /data/database/planet-import-complete /data/tiles/planet-import-complete
        fi

        # Fix postgres data privileges
        chown -R postgres: /var/lib/postgresql/ /data/database/postgres/

        # Configure Apache CORS
        if [ "${ALLOW_CORS:-}" == "enabled" ] || [ "${ALLOW_CORS:-}" == "1" ]; then
            echo "export APACHE_ARGUMENTS='-D ALLOW_CORS'" >> /etc/apache2/envvars
        fi

        if [ "$TILESERVER_MODE" == "RESTORESCP" ] && [ "${TILESERVER_PRERENDER:0}" == "0" ]; then
            mkdir -p $TILESERVER_DATA_PATH
            export TILESERVER_DATA_LABEL_TILE=prerender-$TILESERVER_DATA_LABEL
            scp -i /scpkey/scpkey -o StrictHostKeyChecking=no $TILESERVER_STORAGE_PATH/$TILESERVER_DATA_LABEL_TILE/*.tgz* $TILESERVER_DATA_PATH
            cat $TILESERVER_DATA_PATH/$TILESERVER_DATA_LABEL_TILE.tgz_* | tar xz -C /data/tiles --strip-components=2
            chown -R renderer.renderer /data/tiles/default/
            rm -rf $TILESERVER_DATA_PATH
        fi

        # Initialize PostgreSQL and Apache
        createPostgresConfig
        service postgresql start
        service apache2 restart
        setPostgresPassword

        # Configure renderd threads
        sed -i -E "s/num_threads=[0-9]+/num_threads=${THREADS:-4}/g" /etc/renderd.conf

        # start cron job to trigger consecutive updates
        if [ "${UPDATES:-}" == "enabled" ] || [ "${UPDATES:-}" == "1" ]; then
            /etc/init.d/cron start
            sudo -u renderer touch /var/log/tiles/run.log; tail -f /var/log/tiles/run.log >> /proc/1/fd/1 &
            sudo -u renderer touch /var/log/tiles/osmosis.log; tail -f /var/log/tiles/osmosis.log >> /proc/1/fd/1 &
            sudo -u renderer touch /var/log/tiles/expiry.log; tail -f /var/log/tiles/expiry.log >> /proc/1/fd/1 &
            sudo -u renderer touch /var/log/tiles/osm2pgsql.log; tail -f /var/log/tiles/osm2pgsql.log >> /proc/1/fd/1 &

        fi
    else
        service postgresql start
        service apache2 restart
    fi

    # Run while handling docker stop's SIGTERM
    stop_handler() {
        kill -TERM "$child"
    }
    trap stop_handler SIGTERM

    sudo -u renderer renderd -f -c /etc/renderd.conf &
    child=$!

    if [ "$TILESERVER_MODE" == "RESTORESCP" ] && [ "${TILESERVER_PRERENDER:0}" == "1" ]; then
        sleep 10
        # Norway
        render_list -a -z 1 -Z 1 -x 1 -X 1 -y 0 -Y 0 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 2 -Z 2 -x 2 -X 2 -y 0 -Y 1 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 3 -Z 3 -x 4 -X 4 -y 1 -Y 2 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 4 -Z 4 -x 8 -X 9 -y 3 -Y 4 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 5 -Z 5 -x 16 -X 18 -y 6 -Y 9 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 6 -Z 6 -x 32 -X 37 -y 13 -Y 19 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 7 -Z 7 -x 65 -X 75 -y 26 -Y 38 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 8 -Z 8 -x 131 -X 150 -y 53 -Y 77 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 9 -Z 9 -x 262 -X 301 -y 107 -Y 154 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 10 -Z 10 -x 524 -X 602 -y 214 -Y 309 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 11 -Z 11 -x 1049 -X 1204 -y 429 -Y 618 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 12 -Z 12 -x 2098 -X 2408 -y 859 -Y 1237 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 13 -Z 13 -x 4196 -X 4817 -y 1718 -Y 2475 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 14 -Z 14 -x 8392 -X 9634 -y 3437 -Y 4951 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/
        render_list -a -z 15 -Z 15 -x 16784 -X 19269 -y 6875 -Y 9903 -n 4 -s /run/renderd/renderd.sock -t /data/tiles/

        mkdir -p $TILESERVER_DATA_PATH
        export TILESERVER_DATA_LABEL_TILE=prerender-$TILESERVER_DATA_LABEL
        tar cz /data/tiles | split -b 1024MiB - $TILESERVER_DATA_PATH/$TILESERVER_DATA_LABEL_TILE.tgz_

        mkdir $TILESERVER_DATA_LABEL_TILE
        scp -i /scpkey/scpkey -r -o StrictHostKeyChecking=no $TILESERVER_DATA_LABEL_TILE $TILESERVER_STORAGE_PATH/
        scp -i /scpkey/scpkey -o StrictHostKeyChecking=no $TILESERVER_DATA_PATH/*.tgz* $TILESERVER_STORAGE_PATH/$TILESERVER_DATA_LABEL_TILE
        kill -9 $child
    else
        wait "$child"
    fi

    service postgresql stop

    exit 0
fi

echo "invalid command"
exit 1
