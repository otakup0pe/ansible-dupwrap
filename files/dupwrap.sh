#!/usr/bin/env bash
# Duplicity Wrapper
# Jonathan Freedman <jonafree@gmail.com>

function cleanup {
    if [ "$DESTINATION" == "mac_usb" ] && [ "$ACTION" != "init" ] ; then
        unmount_volume
    fi
}

function log {
    echo "${1}"
    logger "dupwrap ${1}"
}

function problems {
    log "Problems ${1}"
    cleanup
    exit 1
}

function mac_usb_init() {
    if [ -e "/Volumes/${UNENCRYPTED_VOLUME}/${ENCRYPTED_VOLUME}.dmg" ] ; then
        problems "${ENCRYPTED_VOLUME}.dmg already exists"
    fi
    hdiutil create "/Volumes/${UNENCRYPTED_VOLUME}/${ENCRYPTED_VOLUME}.dmg" \
            -size 256m -volname "${ENCRYPTED_VOLUME}" \
            -encryption -fs HFS+J
}

function mount_volume {
    if [ ! -d "/Volumes/${ENCRYPTED_VOLUME}" ]; then
        hdiutil attach "/Volumes/${UNENCRYPTED_VOLUME}/${ENCRYPTED_VOLUME}.dmg"  \
            || problems "Unable to mount ${ENCRYPTED_VOLUME}"
    else
        log "${ENCRYPTED_VOLUME} already mounted"
    fi
}

function unmount_volume {
    if [ -d  "/Volumes/${ENCRYPTED_VOLUME}" ] ; then
        hdiutil detach "/Volumes/${ENCRYPTED_VOLUME}" \
            || problems "Unable to unmount ${ENCRYPTED_VOLUME}"
    else
        log "$ENCRYPTED_VOLUME already unmounted"
    fi
    if [ -d "/Volumes/${UNENCRYPTED_VOLUME}" ] ; then
        hdiutil detach "/Volumes/${UNENCRYPTED_VOLUME}" \
            || problems "Unable to unmount ${UNENCRYPTED_VOLUME}"
    else
        log "$UNENCRYPTED_VOLUME already unmounted"
    fi
}

function backup() {
    INCLUDE=""
    for CDIR in $SOURCE
    do
        TMP=" --include ${CDIR}"
        INCLUDE=${INCLUDE}${TMP}
    done
    START=`date +%s`
    # perform an incremental backup to root, include directories, exclude everything else, / as reference.
    EXCLUDE=""
    if [ "$DROP_JUNK" == "yes" ] ; then
        EXCLUDE="${EXCLUDE} --exclude 'node_modules' --exclude '.git' --exclude '.svn' --exclude '.hg'"
    fi
    duplicity --full-if-older-than 30D \
              $INCLUDE \
              --exclude '**' $EXCLUDE \
              / $D_DESTINATION || problems "Unable to backup"

    if [ $? == 0 ] ; then
        FINISH=`date +%s`
        TIME=`expr $FINISH - $START`
        log "backup succesful after ${TIME}s"
    else
        problems "unable to backup"
    fi
}

function list() {
    duplicity list-current-files $D_DESTINATION
}

function restore() {
    if [ $# == 2 ]; then
        duplicity restore --file-to-restore $1 $D_DESTINATION $2
    else
        duplicity restore --file-to-restore $1 --time $2 $D_DESTINATION $3
    fi
}

function prune() {
    duplicity remove-all-inc-of-but-n-full $KEEP_N_FULL --force $D_DESTINATION && \
        duplicity remove-older-than $REMOVE_OLDER --force $D_DESTINATION || \
            problems "Unable to prune backups"
}

function usage() {
echo "
  dupwrap - manage duplicity backup

  USAGE:

  ./dupwrap.sh backup
  ./dupwrap.sh list
  ./dupwrap.sh status
  ./dupwarp.sh prune
  ./dupwrap.sh restore file [time] dest
  "
}

function status() {
    duplicity collection-status $D_DESTINATION
}

if [ -z "$DUPWRAP_CONF" ] ; then
    if [ "$(whoami)" == "root" ] ; then
        DUPWRAP_CONF="/etc/dupwrap.conf"
    else
        DUPWRAP_CONF="${HOME}/etc/dupwrap.conf"
    fi
fi

if [ ! -e "$DUPWRAP_CONF" ] ; then
    problems "Unable to open $DUPWRAP_CONF"
fi

. $DUPWRAP_CONF

if [ -z "$SOURCE" ] ; then
    problems "Missing source directories"
fi

if [ -z "$DESTINATION" ] ; then
    problems "Missing destination"
fi

if [ -z "$PASSPHRASE" ] ; then
    problems "bad configuration"
fi
export PASSPHRASE="$PASSPHRASE"

if [ "$DESTINATION" == "s3" ] ; then
    if [ -z "$BUCKET" ] || [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] ; then
        problems "bad configuration"
    fi
    D_DESTINATION="$BUCKET"
    export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
elif [ "$DESTINATION" == "mac_usb" ] ; then
    if [ -z "$UNENCRYPTED_VOLUME" ] || [ -z "$ENCRYPTED_VOLUME" ] ; then
        problems "bad configuration"
    fi
    if [ -z "$OS" ] || [ "$OS" != "Darwin" ] ; then
        problems "invalid os"
    fi
    D_DESTINATION="file:///Volumes/${ENCRYPTED_VOLUME}"
fi

if [ $# -lt 1 ] ; then
    problems "invalid syntax"
fi
ACTION="$1"
shift

if [ "$OS" == "Darwin" ] ; then
    if [ "$ACTION" == "init" ] ; then
        mac_usb_init
        exit
    else
        mount_volume
    fi
fi

if [ "$ACTION" == "restore" ] ; then
    if [ $# -gt 2 ] ; then
        RESTORE_FILE="$2"
        RESTORE_DEST="$3"
        shift 2
    elif [ $# -gt 3 ] ; then
        RESTORE_FILE="$2"
        RESTORE_DEST="$4"
        RESTORE_TIME="$3"
        shift 3
    fi
fi
if [ "$ACTION" = "backup" ]; then
    backup
    cleanup
elif [ "$ACTION" = "list" ]; then
    list
    cleanup
elif [ "$ACTION" = "restore" ]; then
    if [ $# = 3 ]; then
        restore $RESTORE_FILE $RESTORE_TIME 
    else
        restore $RESTORE_FILE $RESTORE_TIME $RESTORE_DEST
    fi
    cleanup
elif [ "$ACTION" = "status" ]; then
    status
    cleanup
elif [ "$ACTION" == "prune" ] ; then
    prune
    cleanup
else
    usage
fi
