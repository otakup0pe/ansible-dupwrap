#!/usr/bin/env bash
# Duplicity Wrapper
# Jonathan Freedman <jonafree@gmail.com>
set -e

# Some globals
declare UNENCRYPTED_VOLUME
declare ENCRYPTED_VOLUME
declare OS
declare VERBOSE
declare FORCE

# Some standards
OS="$(uname -s)"
umask 037

# Clean up after ourselves as neccesary
function cleanup {
    if [ ! -z "$CUR_ULIMIT" ] ; then
        ulimit -n "$CUR_ULIMIT"
    fi
    if [ "$DESTINATION" == "mac_usb" ] && [ "$ACTION" != "init" ] ; then
        unmount_volume
    fi
    if [ ! -z "$POST_SCRIPT" ] ; then
        $POST_SCRIPT
    fi
}

# We do occasionally enjoy metrics
function event {
    local EVENT="$1"
    local METRIC
    if [ ! -z "$STATSD_HOST" ] && \
           [ ! -z "$STATSD_PORT" ] && \
           [ ! -z "$STATSD_PROTO" ] ; then
        METRIC="dupwrap.$(hostname -s).${NAME}.${EVENT}:1|c"
        if [ "$OS" == "Linux" ] ; then
            echo "$METRIC" > "/dev/${STATSD_PROTO}/${STATSD_HOST}/${STATSD_PORT}"
        fi
    fi
}
function stat {
    local STAT="$1"
    local VAL="$2"
    local METRIC
    if [ ! -z "$STATSD_HOST" ] && \
           [ ! -z "$STATSD_PORT" ] && \
           [ ! -z "$STATSD_PROTO" ] ; then
        METRIC="dupwrap.$(hostname -s).${NAME}.${STAT}:${VAL}|ms"
        if [ "$OS" == "Linux" ] ; then
            echo "$METRIC" > "/dev/${STATSD_PROTO}/${STATSD_HOST}/${STATSD_PORT}"
        fi
    fi

}

# Just a simple logger
function log {
    echo "${1}"
    logger "dupwrap ${1}"
}

# Just a simple debugger
function dbg {
    if [ ! -z "$VERBOSE" ] ; then
        log "dbg ${1}"
    fi
}

# Just a simple error handler
function problems {
    event error
    log "Problem: ${1}"
    cleanup
    exit 1
}

# Wrap our execution of duplcitiy in order to set the
# archive directory and also redirect output to a tee
# when running non-interactively
function exec_dup {
    A_CMD=("$@")
    CMD="${A_CMD[0]}"
    local START
    local FINISH
    declare -a e_cmd
    e_cmd=(duplicity)
    if [ "$CMD" != "backup" ] ; then
        e_cmd=(${e_cmd[@]} $CMD)
    fi
    e_cmd=(${e_cmd[@]} --name "$NAME")
    if [ ! -z "$VERBOSE" ] ; then
        e_cmd=(${e_cmd[@]} --verbosity debug)
    fi
    if [ ! -z "$ARCHIVE_DIR" ] ; then
        e_cmd=(${e_cmd[@]} --archive-dir "$ARCHIVE_DIR")
    fi
    e_cmd=(${e_cmd[@]} ${A_CMD[@]:1})
    dbg "executing ${e_cmd[*]}"
    START=$(date +%s)
    case "$-" in
        *i*)
            ${e_cmd[*]}
            RC=$?
            ;;
        *)
            ${e_cmd[*]} | tee -a "${LOG_DIRECTORY}/dupwrap.log"
            RC=${PIPESTATUS[0]}
            ;;
    esac
    FINISH=$(date +%s)
    local TIME=$((FINISH - START))
    stat duration "$TIME"
    if [ "$RC" == "0" ] ; then
        log "${CMD} succesful after ${TIME}s"
    else
        problems "UNABLE to ${CMD} after ${TIME}s"
    fi
}

# Will handle the creation of a encrypted disk image on a mac
function mac_usb_init() {
    [ -e "/Volumes/${UNENCRYPTED_VOLUME}/${ENCRYPTED_VOLUME}.dmg" ] && \
        problems "encrypted volume image ${ENCRYPTED_VOLUME}.dmg already exists"
    cmd="hdiutil
           create /Volumes/${UNENCRYPTED_VOLUME}/${ENCRYPTED_VOLUME}.dmg \
           -size $VOLUME_SIZE \
           -volname $ENCRYPTED_VOLUME \
           -stdinpass \
           -encryption -fs HFS+J"
    if [ "$VERBOSE" == "true" ] ; then
        cmd="${cmd} -verbose"
    fi
    dbg "$cmd"
    $cmd <<< "$PASSPHRASE" || \
        problems "Unable to create encrypted volume ${ENCRYPTED_VOLUME}"
}

# Will remove encrypted disk image
function mac_usb_purge() {
    if [ ! -e "/Volumes/${UNENCRYPTED_VOLUME}/${ENCRYPTED_VOLUME}.dmg" ] ; then
        dbg "encrypted volume image ${ENCRYPTED_VOLUME}.dmg already removed"
        exit
    fi
    if [ -z "$FORCE" ] ; then
        echo "Are you sure? (type yes)"
        read -r confirm
        [ "$confirm" == "yes" ] || problems "User unsure"
    fi
    rm -fP "/Volumes/${UNENCRYPTED_VOLUME}/${ENCRYPTED_VOLUME}.dmg"
}

# Will mount the encrypted disk image on a mac
function mount_volume {
    [ -e "/Volumes/${UNENCRYPTED_VOLUME}/${ENCRYPTED_VOLUME}.dmg" ] || \
        problems "encrypted volume image ${ENCRYPTED_VOLUME}.dmg missing"
    if [ ! -d "/Volumes/${ENCRYPTED_VOLUME}" ]; then
        hdiutil \
            attach "/Volumes/${UNENCRYPTED_VOLUME}/${ENCRYPTED_VOLUME}.dmg" \
            -stdinpass <<< "$PASSPHRASE" || \
            problems "Unable to mount encrypted volume ${ENCRYPTED_VOLUME}"
    else
        dbg "encrypted volume ${ENCRYPTED_VOLUME} already mounted"
    fi
}

# Will unmount the encrypted disk image on a mac
function unmount_volume {
    if [ -d  "/Volumes/${ENCRYPTED_VOLUME}" ] ; then
        hdiutil detach "/Volumes/${ENCRYPTED_VOLUME}" \
            || problems "Unable to unmount encrypted voume ${ENCRYPTED_VOLUME}"
    else
        dbg "encrypted volume $ENCRYPTED_VOLUME already unmounted"
    fi
    if [ "$UNMOUNT" == "true" ] ; then
        if [ -d "/Volumes/${UNENCRYPTED_VOLUME}" ] ; then
            hdiutil detach "/Volumes/${UNENCRYPTED_VOLUME}" \
                || problems "Unable to unmount unencrypted voume ${UNENCRYPTED_VOLUME}"
        else
            dbg "Unencrypted volume $UNENCRYPTED_VOLUME already unmounted"
        fi
    else
        dbg "Not unmounting unencrypted volume ${UNENCRYPTED_VOLUME}"
    fi
}

# Performs the actual backup
# perform an incremental backup to root, include directories, exclude everything else, / as reference.
function backup() {
    declare -a cmd
    # don't glob tho
    set -f
    cmd=(backup --full-if-older-than "$FULL_IF_OLDER")
    if [ -n "$WANDERING" ] ; then
        cmd=(${cmd[@]} --allow-source-mismatch)
    fi
    for CDIR in $SOURCE ; do
        cmd=(${cmd[@]} --include "$CDIR")
    done
    cmd=(${cmd[@]} --exclude '**')
    if [ "$DROP_JUNK" == "yes" ] ; then
        cmd=(${cmd[@]} --exclude node_modules --exclude .git --exclude .svn --exclude .hg)
    fi
    cmd=(${cmd[@]} "/" "$BACKUP_TARGET")
    event start
    exec_dup "${cmd[@]}"
    event end
}

# Display a listing of files in the backup set
function list() {
    exec_dup list-current-files "$BACKUP_TARGET"
}

# Restores a file to a specific location
# optionally from a specific time
function restore_file() {
    local FILE="$1"
    local DEST="$2"
    cmd=(restore)
    if [ $# == 2 ]; then
        cmd=(${cmd[@]} --file-to-restore "$FILE" "$BACKUP_TARGET" "$DEST")
    else
        cmd=(${cmd[@]} --file-to-restore "$FILE" --time "$2" "$BACKUP_TARGET" "$3")
    fi
    exec_dup "${cmd[*]}"
}

# Restores the whole thing optionally
# from a specific time
function restore() {
    cmd=(restore)
    if [ $# == 1 ] ; then
        cmd=(${cmd[@]} --force "$BACKUP_TARGET" "$1")
    else
        cmd=(${cmd[@]} --force --time "$1" "$BACKUP_TARGET" "$2")
    fi
    exec_dup "${cmd[*]}"
}

# Removes non incremental and backup sets older than a
# configured amount of time
function prune() {
    event prune_start
    exec_dup remove-all-inc-of-but-n-full "$KEEP_N_FULL" --force "$BACKUP_TARGET"
    exec_dup remove-older-than "$REMOVE_OLDER" --force "$BACKUP_TARGET"
    event prune_end
}

function clean_backups() {
    exec_dup cleanup --force --extra-clean "$BACKUP_TARGET"
}

# Display usage information
function usage() {
    cleanup
    echo "
  dupwrap - manage duplicity backup

  USAGE:

  dupwrap backup
  dupwrap list
  dupwrap status
  dupwarp prune
  dupwrap restore [dest]
  dupwrap restore_file src [time] dest

"
    if [ "$OS" == "Darwin" ] ; then
        echo "
  On macOS:

  dupwrap init
  dupwrap purge
  dupwrap mount
  dupwrap unmount
"
    fi
}

# Display information on current backup set
function status() {
    exec_dup collection-status "$BACKUP_TARGET"
}

if [ $# -lt 1 ] ; then
    usage
fi
ACTION="$1"
UNMOUNT="true"
shift

if [ "$ACTION" == "restore_file" ] ; then
    RESTORE_FILE="$1"
    RESTORE_DEST="$2"
    shift 2
fi

if [ "$ACTION" == "restore" ] ; then
    RESTORE_DEST="$1"
    shift
fi

if [ "$ACTION" == "help" ] ; then
    usage
fi

while getopts "dfvc:p:t:h" arg; do
    case $arg in
        d)
            UNMOUNT="false"
            ;;
        v)
            VERBOSE="true"
            ;;
        f)
            FORCE="true"
            ;;
        c)
            DUPWRAP_CONF="$OPTARG"
            ;;
        p)
            DUPWRAP_PROFILE="$OPTARG"
            ;;
        t)
            RESTORE_TIME="$OPTARG"
            ;;
        h)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

if [ "$(whoami)" == "root" ] ; then
    DUPWRAP_CONF_PREFIX="/etc/dupwrap"
else
    DUPWRAP_CONF_PREFIX="${HOME}/etc/dupwrap"
fi
[ -d "$DUPWRAP_CONF_PREFIX" ] || problems "dupwrap config directory missing, or not set"

if [ -z "$DUPWRAP_CONF" ] && [ -z "$DUPWRAP_PROFILE" ] ; then
    if [ "$ACTION" == "backup" ]  ; then
        dbg "Executing backup for all profiles"
        for p in "${DUPWRAP_CONF_PREFIX}/"*.conf ; do
            VERBOSE="$VERBOSE" "$0" backup -c "$p" -d
        done
        cleanup
        exit
    elif [ "$ACTION" == "prune" ] ; then
        dbg "Executing prune for all profiles"
        for p in "${DUPWRAP_CONF_PREFIX}/"*.conf ; do
            VERBOSE="$VERBOSE" "$0" prune -c "$p"
        done
    else
        problems "must specify profile or config"
    fi
elif [ ! -z "$DUPWRAP_PROFILE" ] ; then
    DUPWRAP_CONF="${DUPWRAP_CONF_PREFIX}/${DUPWRAP_PROFILE}.conf"
fi

if [ ! -e "$DUPWRAP_CONF" ] ; then
    problems "Unable to open $DUPWRAP_CONF"
fi
export DUPWRAP_CONF

# Configuration is externally provisioned
# shellcheck disable=SC1090
. "$DUPWRAP_CONF"

if [ -z "$SOURCE" ] ; then
    problems "Source directories not defined"
fi

if [ -z "$DESTINATION" ] ; then
    problems "Destination not defined"
fi

if [ -z "$PASSPHRASE" ] ; then
    problems "passphrase not defined"
fi
export PASSPHRASE="$PASSPHRASE"

if [ -z "$KEEP_N_FULL" ] ||
       [ -z "$REMOVE_OLDER" ] || \
       [ -z "$FULL_IF_OLDER" ] ; then
    problems "invalid rotation configuration"
fi

if [ "$DESTINATION" == "s3" ] ; then
    if [ -z "$BUCKET" ] || \
           [ -z "$AWS_ACCESS_KEY_ID" ] || \
           [ -z "$AWS_SECRET_ACCESS_KEY" ] ; then
        problems "bad configuration"
    fi
    BACKUP_TARGET="$BUCKET"
    export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
elif [ "$DESTINATION" == "mac_usb" ] ; then
    if [ -z "$UNENCRYPTED_VOLUME" ] || \
           [ -z "$ENCRYPTED_VOLUME" ] || \
           [ -z "$VOLUME_SIZE" ] ; then
        problems "invalid volume configuration"
    fi
    if [ -z "$OS" ] || [ "$OS" != "Darwin" ] ; then
        problems "invalid os"
    fi
    BACKUP_TARGET="file:///Volumes/${ENCRYPTED_VOLUME}"
elif [ "$DESTINATION" == "ftp" ] ; then
    if [ -z "$FTP_USER" ] || \
           [ -z "$FTP_PASSWORD" ] ; then
        problems "invalid ftp configuration"
    fi
    export FTP_PASSWORD
    BACKUP_TARGET="ftp://${FTP_USER}@${FTP_HOST}/${FTP_PATH}"
else
    problems "Unknown destination ${DESTINATION}"
fi


if [ "$OS" == "Darwin" ] ; then
    # lol case insentive -d on macs
    # shellcheck disable=SC2010
    if ! (ls -1 /Volumes | grep "$UNENCRYPTED_VOLUME" &> /dev/null) ; then
        # FAT is always uppercase, so check
        if ! (ls -1 /Volumes | grep "$UNENCRYPTED_VOLUME" &> /dev/null) ; then
            UNMOUNTED="$(diskutil list | grep "$UNENCRYPTED_VOLUME" | cut -c 69-)"
            if [ ! -z "$UNMOUNTED" ] ; then
                diskutil mount "/dev/${UNMOUNTED}"
            else
                problems "unencrypted volume ${UNENCRYPTED_VOLUME} not found"
            fi
        fi
    fi
    if [ "$ACTION" == "init" ] ; then
        mac_usb_init
        exit
    elif [ "$ACTION" == "purge" ] ; then
        mac_usb_purge
        exit
    elif [ "$ACTION" == "mount" ] ; then
        mount_volume
        exit
    elif [ "$ACTION" == "unmount" ] ; then
        unmount_volume
        exit
    else
        mount_volume
    fi
fi
CUR_ULIMIT=$(ulimit -n)
if [ "${CUR_ULIMIT}" -lt 1024 ] ; then
    ulimit -n 1024
    log "ulimit of ${CUR_ULIMIT} is too low"
fi


if [ "$ACTION" = "backup" ]; then
    if [ ! -z "$PRE_SCRIPT" ] ; then
        $PRE_SCRIPT
    fi
    backup
    cleanup
elif [ "$ACTION" = "list" ]; then
    list
    cleanup
elif [ "$ACTION" = "restore" ] ; then
    if [ -z "$RESTORE_TIME" ] ; then
        restore "$RESTORE_DEST"
    else
        restore "$RESTORE_DEST" "$RESTORE_TIME"
    fi
elif [ "$ACTION" = "restore_file" ]; then
    if [ -z "$RESTORE_TIME" ] ; then
        restore_file "$RESTORE_FILE" "$RESTORE_DEST"
    else
        restore_file "$RESTORE_FILE" "$RESTORE_TIME" "$RESTORE_DEST"
    fi
    cleanup
elif [ "$ACTION" = "status" ]; then
    status
    cleanup
elif [ "$ACTION" = "prune" ] ; then
    prune
    cleanup
elif [ "$ACTION" = "clean" ] ; then
    clean_backups
else
    usage
fi
