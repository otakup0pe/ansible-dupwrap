#!/usr/bin/env bash
# Duplicity Wrapper
# Jonathan Freedman <jonafree@gmail.com>
set -e

# Some globals
declare VERBOSE
declare QUIET
declare METRICS

# Some standards
umask 037

# Clean up after ourselves as neccesary
function cleanup {
    if [ -n "$CUR_ULIMIT" ] ; then
        ulimit -n "$CUR_ULIMIT"
    fi
    if [ -n "$POST_SCRIPT" ] ; then
        $POST_SCRIPT
    fi
}

# Just a simple logger
function log {
    >&2 echo "${1}"
    logger "dupwrap ${1}"
}

# Just a simple debugger
function dbg {
    if [ -n "$VERBOSE" ] ; then
        log "dbg ${1}"
    fi
}

# warn tho
function warn {
    log "warning: ${1}"
}

# Just a simple error handler
function problems {
    log "Problem: ${1}"
    cleanup
    exit 1
}

# Write out to prometheus textfile
function prom_write {
    [ "$#" == 3 ] || problems "prom_write invalid args"
    [ -z "$METRICS" ] && return
    local METRIC="$1"
    local TASK="$2"
    local VALUE="$3"
    dbg "prom_write ${METRIC} ${TASK} - ${VALUE}"
    if [ ! -d "$PROMTEXT_PATH" ] ; then
	warn "promtext path is not available"
	return
    fi
    PROMFILE="${PROMTEXT_PATH}/dupwrap-${NAME}.prom"
    if [ -e "$PROMFILE" ] && grep -qE "dupwrap_${METRIC}{task=\"${TASK}\", backup_name=\"${NAME}\"}" "$PROMFILE" ; then
	sed -ri -e "s/(dupwrap_${METRIC}\{task=\"${TASK}\", backup_name=\"${NAME}\"}).+/\1 ${VALUE}/" "$PROMFILE"
    else
	if [ ! -e "$PROMFILE" ] || \
	       ( [ -e "$PROMFILE" ] && ! grep -qE "HELP dupwrap_${METRIC}" "$PROMFILE" ) ; then
	    {
		echo "# HELP dupwrap_${METRIC} dupwrap ${METRIC}" ;
		echo "# TYPE dupwrap_${METRIC} gauge" ;
	    } >> "$PROMFILE"
	fi
	echo "dupwrap_${METRIC}{task=\"$TASK\", backup_name=\"$NAME\"} ${VALUE}" >> "$PROMFILE"
    fi
}

# Wrap our execution of duplicity in order to set the
# archive directory and also redirect output to a tee
# when running non-interactively
function exec_dup {
    A_CMD=("$@")
    CMD="${A_CMD[0]}"
    local START
    local FINISH
    declare -a e_cmd

    # Use uv to run duplicity with managed Python dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SHARE_DIR="$(dirname "${SCRIPT_DIR}")/share/dupwrap"
    if [ -f "${SHARE_DIR}/pyproject.toml" ] ; then
        e_cmd=(uv run --project "${SHARE_DIR}" duplicity)
    else
        problems "pyproject.toml not found at ${SHARE_DIR}"
    fi
    if [ "$CMD" != "backup" ] ; then
        e_cmd+=("$CMD")
    fi
    e_cmd+=(--name "$NAME")
    log_level="notice"
    if [ -n "$VERBOSE" ] ; then
	log_level="debug"
    elif [ -n "$QUIET" ] ; then
	log_level="warning"
    fi
    e_cmd+=(--verbosity "$log_level")
    if [ -n "$ARCHIVE_DIR" ] ; then
        e_cmd+=(--archive-dir "$ARCHIVE_DIR")
	export TMPDIR="${ARCHIVE_DIR}"
    fi
    e_cmd+=("${A_CMD[@]:1}")
    dbg "executing ${e_cmd[*]}"
    START=$(date +%s)
    if [ -n "$QUIET" ] ; then
	"${e_cmd[@]}" >> "${LOG_DIRECTORY}/dupwrap-${DUPWRAP_PROFILE}.log"
    else
	"${e_cmd[@]}" | tee -a "${LOG_DIRECTORY}/dupwrap-${DUPWRAP_PROFILE}.log"
    fi
    RC=${PIPESTATUS[0]}
    FINISH=$(date +%s)
    local TIME=$((FINISH - START))
    if [ "$RC" == "0" ] ; then
	if [ -z "$QUIET" ] ; then
            log "${CMD} succesful after ${TIME}s"
	fi
    else
	if [ "$CMD" == "backup" ] ; then
	    prom_write "status" "error" "$TIME"
	    prom_write "time" "error" "$FINISH"
	fi
        problems "UNABLE to ${CMD} after ${TIME}s"
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
        cmd+=(--allow-source-mismatch)
    fi
    for CDIR in $SOURCE ; do
        cmd+=(--include "$CDIR")
    done
    cmd+=(--exclude '**')
    if [ "$DROP_JUNK" == "yes" ] ; then
        cmd+=(--exclude node_modules --exclude .git --exclude .svn --exclude .hg)
    fi
    cmd+=("/" "$BACKUP_TARGET")
    START="$(date '+%s')"
    exec_dup "${cmd[@]}"
    END="$(date '+%s')"
    TIME="$((END - START))"
    prom_write "status" "backup" "$TIME"
    prom_write "time" "backup" "$END"
}

# Display a listing of files in the backup set
function list() {
    declare -a cmd
    cmd=(list-current-files)
    if [ -n "$RESTORE_TIME" ] ; then
        cmd+=(--time "$RESTORE_TIME")
    fi
    cmd+=("$BACKUP_TARGET")
    exec_dup "${cmd[@]}"
}

function verify() {
    declare -a cmd
    cmd=(verify)
    if [ -n "$RESTORE_TIME" ] ; then
        cmd+=(--time "$RESTORE_TIME")
    fi
    for CDIR in $SOURCE ; do
        cmd+=(--include "$CDIR")
    done
    cmd+=(--exclude '**')
    cmd+=("$BACKUP_TARGET" "/")
    START="$(date '+%s')"
    exec_dup "${cmd[@]}"
    END="$(date '+%s')"
    TIME="$((END - START))"
    prom_write "status" "verify" "$TIME"
    prom_write "time" "verify" "$END"
}

# Restores a file to a specific location
# optionally from a specific time
function restore_file() {
    local FILE="$1"
    local DEST="$2"
    cmd=(restore)
    if [ $# == 2 ]; then
        cmd+=(--path-to-restore "$FILE" "$BACKUP_TARGET" "$DEST")
    else
        cmd+=(--path-to-restore "$FILE" --time "$2" "$BACKUP_TARGET" "$3")
    fi
    exec_dup "${cmd[@]}"
}

# Restores the whole thing optionally
# from a specific time
function restore() {
    cmd=(restore)
    if [ $# == 1 ] ; then
        cmd+=(--force "$BACKUP_TARGET" "$1")
    else
        cmd+=(--force --time "$1" "$BACKUP_TARGET" "$2")
    fi
    exec_dup "${cmd[@]}"
}

# Removes non incremental and backup sets older than a
# configured amount of time
function prune() {
    START="$(date '+%s')"
    exec_dup remove-all-inc-of-but-n-full "$KEEP_N_FULL" --force "$BACKUP_TARGET"
    exec_dup remove-older-than "$REMOVE_OLDER" --force "$BACKUP_TARGET"
    END="$(date '+%s')"
    TIME="$((END - START))"
    prom_write "status" "prune" "$TIME"
    prom_write "time" "prune" "$END"
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
  dupwrap list [-t time]
  dupwrap verify [-t time]
  dupwrap status
  dupwrap prune (old backups)
  dupwrap clean (failed backups)
  dupwrap restore [dest]
  dupwrap restore_file src [time] dest

"
}

# Display information on current backup set
function status() {
    exec_dup collection-status "$BACKUP_TARGET"
}

if [ $# -lt 1 ] ; then
    usage
fi
ACTION="$1"
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

while getopts "qvc:p:t:h" arg; do
    case $arg in
	q)
	    QUIET="true"
	    ;;
        v)
            VERBOSE="true"
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

if [ -n "$QUIET" ] && [ -n "$VERBOSE" ] ; then
    problems "please do not specify verbose and quiet at the same time"
fi

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
            VERBOSE="$VERBOSE" QUIET="$QUIET" "$0" backup -c "$p"
        done
        cleanup
        exit
    elif [ "$ACTION" == "prune" ] ; then
        dbg "Executing prune for all profiles"
        for p in "${DUPWRAP_CONF_PREFIX}/"*.conf ; do
            VERBOSE="$VERBOSE" QUIET="$QUIET" "$0" prune -c "$p"
        done
    else
        problems "must specify profile or config"
    fi
elif [ -n "$DUPWRAP_PROFILE" ] ; then
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

if [ -n "$CRED_SCRIPT" ] ; then
    if [ ! -f "$CRED_SCRIPT" ] ; then
        problems "CRED_SCRIPT not found: ${CRED_SCRIPT}"
    fi
    if [ ! -r "$CRED_SCRIPT" ] ; then
        problems "CRED_SCRIPT not readable: ${CRED_SCRIPT}"
    fi
    # shellcheck disable=SC1090
    . "$CRED_SCRIPT" || problems "CRED_SCRIPT failed: ${CRED_SCRIPT}"
fi

if [ "$DESTINATION" == "s3" ] ; then
    if [ -z "$BUCKET" ] ; then \
        problems "bad configuration"
    fi
    BACKUP_TARGET="$BUCKET"
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] ; then
       export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
       export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
    fi
elif [ "$DESTINATION" == "local" ] ; then
    if [ -z "$LOCAL_PATH" ] ; then
        problems "LOCAL_PATH not defined for local destination"
    fi
    if [ ! -d "$LOCAL_PATH" ] ; then
        mkdir -p "$LOCAL_PATH" || problems "Unable to create local backup path ${LOCAL_PATH}"
    fi
    BACKUP_TARGET="file://${LOCAL_PATH}"
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

# Override backup target for restore operations if RESTORE_SOURCE is set
if [ -n "$RESTORE_SOURCE" ] ; then
    if [ "$ACTION" = "restore" ] || [ "$ACTION" = "restore_file" ] ; then
        log "Using restore source override: ${RESTORE_SOURCE}"
        BACKUP_TARGET="$RESTORE_SOURCE"
    fi
fi

CUR_ULIMIT=$(ulimit -n)
if [ "${CUR_ULIMIT}" -lt 1024 ] ; then
    ulimit -n 1024
    log "ulimit of ${CUR_ULIMIT} is too low"
fi


if [ "$ACTION" = "backup" ]; then
    if [ -n "$PRE_SCRIPT" ] ; then
        $PRE_SCRIPT
    fi
    backup
    cleanup
elif [ "$ACTION" = "list" ]; then
    list
    cleanup
elif [ "$ACTION" = "verify" ]; then
    verify
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
