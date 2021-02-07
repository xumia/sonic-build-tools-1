#!/bin/bash -e

CREATE_DB=$1
MIRROR_NAME=$2

WORK_DIR=work
SOURCE_DIR=$(pwd)
SAVE_WORKSPACE=n
IS_DIRTY_VERSION=n
APTLY_CONFIG=aptly-debian.conf
PACKAGES_DENY_LIST=debian-packages-denylist.conf
VERSION_FILE=_aptly/version
ENCRIPTED_KEY_GPG=./encrypted_private_key.gpg
DEBIAN_MIRRORS_CONFIG=azure-pipelines/config/debian-mirrors.config
DATABASE_VERSION_FILENAME=${MIRROR_NAME}-database-version
DEBIAN_MIRROR_URL="https://deb.debian.org/debian"
DEBINA_SECURITY_MIRROR_URL="http://security.debian.org/debian-security"
export GNUPGHOME=gnupg
GPG_FILE=$GNUPGHOME/mykey.gpg
BLOBFUSE_METTRIC_DIR=_storage_data/metric
BLOBFUSE_DB_DIR=_storage_data/aptly/$MIRROR_NAME/dbs

MIRROR_CONFIG=$(grep -e "^$MIRROR_NAME\s" $DEBIAN_MIRRORS_CONFIG | tail -n 1)
MIRROR_FILESYSTEM=$(echo $MIRROR_CONFIG | awk '{print $2}')
MIRROR_URL=$(echo $MIRROR_CONFIG | awk '{print $3}')
MIRROR_DISTRIBUTIONS=$(echo $MIRROR_CONFIG | awk '{print $4}')
MIRROR_COMPONENTS=$(echo $MIRROR_CONFIG | awk '{print $5}')
MIRROR_ARICHTECTURES=$(echo $MIRROR_CONFIG | awk '{print $6}')
FILESYSTEM="filesystem:$MIRROR_FILESYSTEM:"
APTLIY_MIRROR_PATH=_storage_data/aptly/$MIRROR_NAME

cd $WORK_DIR

validate_input_variables()
{
    if [ -z "$MIRROR_NAME" ]; then
        echo "DIST is empty" 1>&2
        exit 1
    fi

    if [ -z "$MIRROR_CONFIG" ]; then
        echo "The debian mirros config is empty, please check $DEBIAN_MIRRORS_CONFIG" 1>&2
        exit 1
    fi

    if [ -z "$GPG_KEY" ]; then
        echo "The encrypted gpg key is not set." 1>&2
        exit 1
    fi

    if [ -z "$MIRROR_VERSION" ]; then
        echo "The MIRROR_VERSION env is not set." 1>&2
        exit 1
    fi

    if [ -z "$PASSPHRASE" ]; then
        echo "The passphrase is not set." 1>&2
        exit 1
    fi

    if ! readlink _storage_data > /dev/null; then
        echo "$WORK_DIR/_storage_data is not a symbol link" 1>&2
        exit 1
    fi  
}

check_dirty_version()
{
    local database_version=none
    local publish_version=
    local database_version_file=db/$DATABASE_VERSION_FILENAME
    local publish_version_file=publish/versions/$DATABASE_VERSION_FILENAME
    [ -f $database_version_file ] && database_version=$(cat $database_version_file)
    [ -f $publish_version_file ] && publish_version=$(cat $publish_version_file)
    local is_dirty_version=n
    if [ "$database_version" != "$publish_version" ]; then
        is_dirty_version=y
    fi
    echo $is_dirty_version
}

prepare_workspace()
{
    echo "pwd=$(pwd)"
    mkdir -p $BLOBFUSE_DB_DIR $BLOBFUSE_METTRIC_DIR
    cp $SOURCE_DIR/azure-pipelines/config/aptly-debian.conf $APTLY_CONFIG
    cp $SOURCE_DIR/azure-pipelines/config/debian-packages-denylist.conf $PACKAGES_DENY_LIST

    # Import gpg key
    rm -rf $GNUPGHOME
    mkdir $GNUPGHOME
    echo "pinentry-mode loopback" > $GNUPGHOME/gpg.conf
    echo "$GPG_KEY" > $ENCRIPTED_KEY_GPG
    chmod 600 $GNUPGHOME/*
    chmod 700 $GNUPGHOME
    gpg --no-default-keyring --passphrase="$PASSPHRASE" --keyring=$GPG_FILE --import "$ENCRIPTED_KEY_GPG"

    if [ -e db ]; then
        rm -rf db
    fi

    if [ "$CREATE_DB" == "y" ]; then
        return
    fi
    local latest_db=$(ls -Ar $BLOBFUSE_DB_DIR/db-*.gz 2>/dev/null | head -n 1)
    if [ -z "$latest_db" ]; then
        #echo "Please create the aptly database and try again." 1>&2
        #exit 1
        echo "The database is empty, create a new database"
        return
    fi

    echo "The latest db file is $latest_db."
    tar -xzvf "$latest_db" -C .
    IS_DIRTY_VERSION=$(check_dirty_version)
    echo "IS_DIRTY_VERSION=$IS_DIRTY_VERSION"
}

save_workspace()
{
    local package="$BLOBFUSE_DB_DIR/db-$(date +%Y%m%d%H%M%S).tar.gz"
    local database_version_file=db/$DATABASE_VERSION_FILENAME
    local latest_database_version_file=$APTLIY_MIRROR_PATH/version
    local publish_version_file=publish/versions/$DATABASE_VERSION_FILENAME
    local public_key_file_asc=publish/public_key.asc
    local public_key_file_gpg=publish/public_key.gpg

    mkdir -p publish/versions
    if [ "$IS_DIRTY_VERSION" == "y" ] && [ -f "$database_version_file" ]; then
        cp "$database_version_file" "$publish_version_file"
        if [ ! -z "$GPG_PUBLIC_KEY2" ]; then
            echo "$GPG_PUBLIC_KEY2" > gpg_public_key2.asc
            gpg --no-default-keyring --keyring=$GPG_FILE --import gpg_public_key2.asc
        fi
        gpg --no-default-keyring --keyring=$GPG_FILE --export -a > "$public_key_file_asc"
        gpg --no-default-keyring --keyring=$GPG_FILE --export > "$public_key_file_gpg"
    fi

    if [ -f "$database_version_file" ] && [ ! -f "$latest_database_version_file" ]; then
        cp "$database_version_file" "$latest_database_version_file"
    fi

    if [ "$SAVE_WORKSPACE" == "n" ]; then
        cp "$database_version_file" "$publish_version_file"
        cp "$database_version_file" "$latest_database_version_file"
        return
    fi

    if [ "$UPDATE_MIRROR" != "y" ]; then
        return
    fi

    #local version=$(date +%Y%m%d%H%M%S-%N)
    local version=$MIRROR_VERSION
    echo "Saving the db version $version"
    echo $version > $database_version_file
    cp "$database_version_file" "$publish_version_file"
    cp "$database_version_file" "$latest_database_version_file"
    gpg --no-default-keyring --keyring=$GPG_FILE --export -a > "$public_key_file_asc"
    gpg --no-default-keyring --keyring=$GPG_FILE --export > "$public_key_file_gpg"
    tar -czvf "$package" db
    echo $version > $VERSION_FILE
    echo "Saving workspace to $package is complete"
}

update_repo()
{
    local name=$1
    local url=$2
    local dist=$3
    local archs=$4
    local components=$5
    local distname=$(echo $dist | tr '/' '_')
    local version_file=$APTLIY_MIRROR_PATH/version
    local dist_version_file=${version_file}-${distname}
    local cur_db_version=$MIRROR_VERSION
    local published_version=
    [ -f $version_file ] && cur_db_version=$(cat $version_file)
    if [ -f $dist_version_file ]; then
        cur_db_version=$(cat $dist_version_file)
    else
        echo $cur_db_version > $dist_version_file
    fi

    # Check if the distribution has been published
    [ -f publish/versions/$DATABASE_VERSION_FILENAME ] && published_version=$(cat publish/versions/$DATABASE_VERSION_FILENAME)
    if [ "$CREATE_DB" != "y" ] && [ "$UPDATE_MIRROR" != "y" ] && [[ ! "$published_version" < "$cur_db_version" ]] ; then
        echo "Skipped to publish $dist, the published version is $published_version, and current db version is $cur_db_version"
        return
    fi

    # Create the aptly mirrors if it does not exist
    local repos=
    local need_to_publish=n
    [ "$CREATE_DB" == "y" ] && need_to_publish=y
    for component in $(echo $components | tr ',' ' '); do
        local mirror="mirror-${name}-${distname}-${component}"
        local repo="repo-${name}-${distname}-${component}"
        local logfile="${mirror}.log"
        local current_url=$url

        # Create the aptly mirror if not existing
        if ! aptly -config $APTLY_CONFIG mirror show $mirror > /dev/null 2>&1; then
            if [ "$UPDATE_MIRROR" != "y" ]; then
                echo "The mirror does not exit $mirror, not to create it, since UPDATE_MIRROR=$UPDATE_MIRROR" 1>&2
                exit 1
            fi
            WITH_SOURCES="-with-sources"
            [ "$dist" == "jessie" ] && WITH_SOURCES=""
            if [ "$component" != "amd64" ]; then
                current_url=$DEBIAN_MIRROR_URL
                [[ "$current_url" == *security* ]] && current_url=$DEBINA_SECURITY_MIRROR_URL
            fi
            aptly -config $APTLY_CONFIG -ignore-signatures -architectures="$archs" mirror create $WITH_SOURCES $mirror $url $dist $component
            SAVE_WORKSPACE=y
        fi

        # Remove the packages in the deny list
        if aptly -config $APTLY_CONFIG repo show $repo > /dev/null 2>&1; then
            while IFS= read -r line
            do
                # trim the line
                local filter=$(echo $line | awk '{$1=$1};1')
                if [ -z "filter" ]; then
                    continue
                fi

                aptly -config $APTLY_CONFIG repo remove $repo $filter
           done < $PACKAGES_DENY_LIST
        fi

        repos="$repos $repo"
        if [ "$UPDATE_MIRROR" != "y" ]; then
            echo "Skip to update the mirror $mirror, UPDATE_MIRROR=$UPDATE_MIRROR"
            continue
        fi
        
        local success=n
        local has_error=n
        local retry=5
        # Update the aptly mirror with retry
        for ((i=1;i<=$retry;i++)); do
            echo "Try to update the mirror, retry step $i of $retry"
            aptly -config $APTLY_CONFIG -ignore-signatures mirror update -max-tries=5 $mirror | tee $logfile
            if [ "$?" -eq "0" ]; then
                echo "Successfully update the mirror $mirror"
                success=y
                break
            else
                echo "Failed to update the mirror $mirror, sleep 10 seconds"
                sleep 10
                has_error=y
            fi
        done
        if [ "$success" != "y" ]; then
            echo "Failed to update the mirror $mirror" 1>&2
            exit 1
        fi

        # Create the aptly repo if not existing
        if ! aptly -config $APTLY_CONFIG repo show $repo > /dev/null 2>&1; then
            aptly -config $APTLY_CONFIG repo create $repo
        elif [ "$has_error" == "n" ] && grep -q "Download queue: 0 items" $logfile; then
            continue
        fi

        # Import the packages to the aptly repo
        need_to_publish=y
        echo "Importing mirror $mirror to repo $repo"
        aptly -config $APTLY_CONFIG repo import $mirror $repo 'Name (~ .*)' >> ${repo}.log

        # Remove the packages in the deny list
        while IFS= read -r line
        do
            # trim the line
            local filter=$(echo $line | awk '{$1=$1};1')
            if [ -z "filter" ]; then
                continue
            fi

            aptly -config $APTLY_CONFIG repo remove $repo $filter
        done < $PACKAGES_DENY_LIST
    done

    # Check if there are any new packages to publish
    echo "Start publish repos $dist need_to_publish=$need_to_publish IS_DIRTY_VERSION=$IS_DIRTY_VERSION"
    [ "$need_to_publish" == "y" ] && SAVE_WORKSPACE=y
    if [ "$need_to_publish" != "y" ] && [ "$IS_DIRTY_VERSION" == "n" ]; then
        echo "Skip publish repos $dist"
        return
    fi

    [ "$UPDATE_MIRROR" == "y" ] && echo $MIRROR_VERSION > $dist_version_file

    # Set the publish options
    local options=
    [[ "$dist" == *-backports ]] && options="-notautomatic=yes -butautomaticupgrades=yes"

    # Publish the aptly repo with retry
    echo "Publish repos: $repos"
    local publish_dist=$distname
    local retry=5
    local publish_succeeded=n
    local wait_seconds=300
    for ((i=1;i<=$retry;i++)); do
        echo "Try to publish $publish_dist $FILESYSTEM, retry step $i of $retry"
        if ! aptly -config $APTLY_CONFIG publish show $publish_dist $FILESYSTEM > /dev/null 2>&1; then
            echo "aptly -config $APTLY_CONFIG publish repo $options -passphrase=*** -keyring=$GPG_FILE -distribution=$publish_dist -architectures=$archs -component=$components $repos $FILESYSTEM"
            if aptly -config $APTLY_CONFIG publish repo $options -passphrase="$PASSPHRASE" -keyring=$GPG_FILE -distribution=$publish_dist -architectures=$archs -component=$components $repos $FILESYSTEM; then
                publish_succeeded=y
                break
            fi
        else
            echo "Publish Repos=$repos publish_dist=$publish_dist"
            if aptly -config $APTLY_CONFIG publish update -passphrase="$PASSPHRASE" -keyring=$GPG_FILE -skip-cleanup $publish_dist $FILESYSTEM; then
                publish_succeeded=y
                break
            fi
        fi

        if [ "$i" != "$retry" ]; then
            echo "Sleep $wait_seconds seconds"
            sleep $wait_seconds
        fi
    done

    if [ "$publish_succeeded" != "y" ]; then
        echo "Failed to publish $publish_dist $FILESYSTEM after $retry retries" 1>&2
        exit 1
    fi

    if [ ! -z "$PUBLISH_FLAG" ]; then
        touch "$PUBLISH_FLAG"
    fi
}

validate_input_variables
prepare_workspace
for distribution in $(echo $MIRROR_DISTRIBUTIONS | tr ',' ' '); do
    echo "update repo for url=$MIRROR_URL name=$MIRROR_NAME distribution=$distribution architectures=$MIRROR_ARICHTECTURES components=$MIRROR_COMPONENTS"
    update_repo $MIRROR_NAME "$MIRROR_URL" $distribution "$MIRROR_ARICHTECTURES" "$MIRROR_COMPONENTS"
done
save_workspace
