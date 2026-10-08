#!/usr/bin/env bash
# Duplicity Wrapper
# Jonathan Freedman <jonafree@gmail.com>
set -e

declare VERBOSE
declare QUIET
declare METRICS
# CLI paths and the resolved per-run scope. Each scope path requires its own
# duplicity invocation because --path-to-restore accepts only one.
declare -a VERIFY_INCLUDE=()
declare -a VERIFY_SCOPE=()
# Aggregate evidence and the first failure of each kind for the current verify.
declare VERIFY_COMPARED
declare VERIFY_DIFFERING
declare VERIFY_EMPTY_PATH
declare VERIFY_SUMMARY_MISSING
declare VERIFY_MISSING_LOCAL

umask 037

function cleanup {
    if [ -n "$CUR_ULIMIT" ] ; then
        ulimit -n "$CUR_ULIMIT"
    fi
    if [ -n "$POST_SCRIPT" ] ; then
        $POST_SCRIPT
    fi
}

function log {
    >&2 echo "${1}"
    logger "dupwrap ${1}"
}

function dbg {
    if [ -n "$VERBOSE" ] ; then
        log "dbg ${1}"
    fi
}

function warn {
    log "warning: ${1}"
}

function problems {
    log "Problem: ${1}"
    cleanup
    exit 1
}

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

# Reassert the log's ownership contract if it is recreated between runs.
function prepare_log {
    local LOG_FILE="${LOG_DIRECTORY}/dupwrap-${DUPWRAP_PROFILE}.log"
    if [ ! -e "$LOG_FILE" ] ; then
        : > "$LOG_FILE"
    fi
    chmod 0640 "$LOG_FILE"
    chgrp "$LOG_GROUP" "$LOG_FILE"
}

# Run duplicity with the profile archive directory and persistent logging.
function exec_dup {
    A_CMD=("$@")
    CMD="${A_CMD[0]}"
    local START
    local FINISH
    declare -a e_cmd

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SHARE_DIR="$(dirname "${SCRIPT_DIR}")/share/dupwrap"
    # Cron may omit uv's install directory from PATH.
    UV_BIN="$(command -v uv 2>/dev/null || true)"
    if [ -z "$UV_BIN" ] ; then
        for _uv_cand in \
            /usr/local/bin/uv \
            "${HOME}/.local/bin/uv" \
            /root/.local/bin/uv \
            /home/rewt/.local/bin/uv ; do
            if [ -x "$_uv_cand" ] ; then
                UV_BIN="$_uv_cand"
                break
            fi
        done
    fi
    if [ -z "$UV_BIN" ] ; then
        problems "uv not found on PATH or known install locations"
    fi
    if [ -f "${SHARE_DIR}/pyproject.toml" ] ; then
        e_cmd=("$UV_BIN" run --project "${SHARE_DIR}" duplicity)
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
	# Verification needs duplicity's notice-level comparison summary.
	if [ "$CMD" == "verify" ] ; then
	    log_level="notice"
	else
	    log_level="warning"
	fi
    fi
    e_cmd+=(--verbosity "$log_level")
    if [ -n "$ARCHIVE_DIR" ] ; then
        e_cmd+=(--archive-dir "$ARCHIVE_DIR")
	export TMPDIR="${ARCHIVE_DIR}"
    fi
    e_cmd+=("${A_CMD[@]:1}")
    dbg "executing ${e_cmd[*]}"
    prepare_log
    START=$(date +%s)
    # Capture rc before set -e can bypass failure metrics and logging.
    RC=0
    if [ -n "$QUIET" ] ; then
	"${e_cmd[@]}" >> "${LOG_DIRECTORY}/dupwrap-${DUPWRAP_PROFILE}.log" 2>&1 || RC=$?
    else
	"${e_cmd[@]}" 2>&1 | tee -a "${LOG_DIRECTORY}/dupwrap-${DUPWRAP_PROFILE}.log"
	RC=${PIPESTATUS[0]}
    fi
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
	elif [ "$CMD" == "verify" ] ; then
	    prom_write "status" "verify_error" "$TIME"
	    prom_write "time" "verify_error" "$FINISH"
	elif [ "$CMD" == "remove-all-inc-of-but-n-full" ] || \
		 [ "$CMD" == "remove-older-than" ] ; then
	    # problems() exits before prune() can publish its own failure.
	    prom_write "status" "prune_error" "$TIME"
	    prom_write "time" "prune_error" "$FINISH"
	fi
        problems "UNABLE to ${CMD} after ${TIME}s (rc=${RC})"
    fi
}

# Export run statistics so a successful but unexpectedly full backup is
# alertable. The last occurrence belongs to the run exec_dup just appended.
function prom_write_backup_stats {
    local LOG="${LOG_DIRECTORY}/dupwrap-${DUPWRAP_PROFILE}.log"
    [ -r "$LOG" ] || return 0
    local KEY VALUE METRIC TAIL
    TAIL="$(tail -n 400 "$LOG")"
    for KEY in SourceFiles SourceFileSize NewFiles NewFileSize \
               DeletedFiles ChangedFiles TotalDestinationSizeChange ; do
        VALUE="$(printf '%s\n' "$TAIL" | awk -v k="$KEY" \
            '$1 == k { v = $2 } END { if (v != "") print v }')"
        [ -n "$VALUE" ] || continue
        METRIC="$(printf '%s' "$KEY" \
            | sed -re 's/([a-z0-9])([A-Z])/\1_\2/g' \
            | tr '[:upper:]' '[:lower:]')"
        prom_write "$METRIC" "backup" "$VALUE"
    done
}

function backup() {
    declare -a cmd
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
    prom_write_backup_stats
}

function list() {
    declare -a cmd
    cmd=(list-current-files)
    if [ -n "$RESTORE_TIME" ] ; then
        cmd+=(--time "$RESTORE_TIME")
    fi
    cmd+=("$BACKUP_TARGET")
    exec_dup "${cmd[@]}"
}

# --path-to-restore addresses an entry inside the "/" archive root, so scope
# paths use the relative form printed by `dupwrap list`. Reject a leading
# slash instead of silently normalizing a misconfigured path.
function assert_relative_include {
    case "$1" in
        /*) problems "verify include path must be relative to the backup root, got: ${1}" ;;
        *) ;;
    esac
}

# CLI paths override the newline-delimited profile file. The separate file
# preserves spaces and shell metacharacters that a sourced config cannot.
function verify_scope {
    local line
    VERIFY_SCOPE=()
    if [ "${#VERIFY_INCLUDE[@]}" -gt 0 ] ; then
        for line in "${VERIFY_INCLUDE[@]}" ; do
            assert_relative_include "$line"
            VERIFY_SCOPE+=("$line")
        done
    elif [ -n "$VERIFY_INCLUDE_FILE" ] && [ -s "$VERIFY_INCLUDE_FILE" ] ; then
        # Validate hand edits too, preserving bytes and an unterminated final
        # line.
        while IFS= read -r line || [ -n "$line" ] ; do
            [ -n "$line" ] || continue
            assert_relative_include "$line"
            VERIFY_SCOPE+=("$line")
        done < "$VERIFY_INCLUDE_FILE"
    fi
}

# Duplicity reports one compared file when a scope path is absent locally and
# from the archive. Refuse that vacuous success before running it. Test the
# same "/${CPATH}" target verify passes to duplicity; -e permits directories
# and symlinks.
function scope_local_present {
    local CPATH="$1"
    if [ -e "/${CPATH}" ] ; then
        return 0
    fi
    if [ -z "$VERIFY_MISSING_LOCAL" ] ; then
        VERIFY_MISSING_LOCAL="$CPATH"
    fi
    return 1
}

# Parse only the log slice appended by this invocation. Per-run offsets keep
# earlier runs from supplying evidence and ensure every scoped path counts.
function verify_run {
    local LABEL="$1"
    shift
    local LOG="${LOG_DIRECTORY}/dupwrap-${DUPWRAP_PROFILE}.log"
    local OFFSET=0
    local TAIL COUNT DIFFS

    # The first invocation may not have a log yet.
    if [ -r "$LOG" ] ; then
        OFFSET="$(wc -c < "$LOG" | tr -d '[:space:]')"
    fi
    exec_dup "$@"
    TAIL="$(tail -c "+$((OFFSET + 1))" "$LOG" 2>/dev/null || true)"
    COUNT="$(printf '%s\n' "$TAIL" \
        | sed -nre 's/^Verify complete: ([0-9]+) file\(s\) compared.*/\1/p' \
        | tail -n 1)"
    DIFFS="$(printf '%s\n' "$TAIL" \
        | sed -nre 's/^Verify complete: [0-9]+ file\(s\) compared, ([0-9]+) difference\(s\) found.*/\1/p' \
        | tail -n 1)"

    if [ -z "$COUNT" ] ; then
        # Defer failure so the whole verify publishes one coherent result.
        if [ -z "$VERIFY_SUMMARY_MISSING" ] ; then
            VERIFY_SUMMARY_MISSING="${LABEL:-the source tree}"
        fi
        return 0
    fi
    VERIFY_COMPARED="$((VERIFY_COMPARED + COUNT))"
    # An absent difference count is unknown, not zero.
    if [ -n "$DIFFS" ] ; then
        VERIFY_DIFFERING="$(( ${VERIFY_DIFFERING:-0} + DIFFS ))"
    fi
    if [ "$COUNT" -eq 0 ] && [ -z "$VERIFY_EMPTY_PATH" ] ; then
        VERIFY_EMPTY_PATH="${LABEL:-the source tree}"
    fi
    dbg "verify compared ${COUNT} file(s) for ${LABEL:-the source tree}"
}

# Duplicity exits 0 when it compares nothing. Require a readable summary,
# non-zero aggregate, and non-zero evidence from every scoped invocation.
# Report a locally missing scope first because it is a scope error, not an
# archive failure.
function assert_files_compared {
    local TIME="$1"
    local END="$2"

    if [ -n "$VERIFY_SUMMARY_MISSING" ] ; then
        prom_write "status" "verify_error" "$TIME"
        prom_write "time" "verify_error" "$END"
        problems "could not read duplicity's verify summary for ${VERIFY_SUMMARY_MISSING}, so nothing proves the archive was compared"
    fi
    # Aggregate every scoped invocation into one coverage metric.
    prom_write "files_compared" "verify" "$VERIFY_COMPARED"
    if [ -n "$VERIFY_DIFFERING" ] ; then
        prom_write "files_differing" "verify" "$VERIFY_DIFFERING"
    fi
    # Prefer the actionable scope diagnosis. Counts from paths that ran remain
    # valid.
    if [ -n "$VERIFY_MISSING_LOCAL" ] ; then
        prom_write "status" "verify_error" "$TIME"
        prom_write "time" "verify_error" "$END"
        problems "verify scope names ${VERIFY_MISSING_LOCAL} but /${VERIFY_MISSING_LOCAL} does not exist on this host -- SCOPE CONFIGURATION ERROR, not an archive failure: that path is absent on both sides, so comparing it would prove nothing while exiting 0. Fix or remove the path from verify_include; do not restore"
    fi
    if [ "$VERIFY_COMPARED" -eq 0 ] ; then
        prom_write "status" "verify_error" "$TIME"
        prom_write "time" "verify_error" "$END"
        problems "verify compared 0 files -- nothing in the scope is in the archive, so this verify proved nothing"
    fi
    if [ -n "$VERIFY_EMPTY_PATH" ] ; then
        prom_write "status" "verify_error" "$TIME"
        prom_write "time" "verify_error" "$END"
        problems "verify compared 0 files for ${VERIFY_EMPTY_PATH} -- that path is not in the archive, so this verify proved nothing about it"
    fi
    dbg "verify compared ${VERIFY_COMPARED} file(s) in total"
}

# Scoped verification samples named archive entries. Duplicity 3.0.7 ignores
# verify include filters, so each --path-to-restore requires a separate run.
# A sample proves only that those entries decrypt and match.
function verify() {
    declare -a cmd
    local CPATH
    VERIFY_COMPARED=0
    VERIFY_DIFFERING=""
    VERIFY_EMPTY_PATH=""
    VERIFY_SUMMARY_MISSING=""
    VERIFY_MISSING_LOCAL=""
    verify_scope
    START="$(date '+%s')"
    if [ "${#VERIFY_SCOPE[@]}" -gt 0 ] ; then
        for CPATH in "${VERIFY_SCOPE[@]}" ; do
            if ! scope_local_present "$CPATH" ; then
                warn "verify scope path ${CPATH} has no local counterpart at /${CPATH}, refusing to compare it"
                continue
            fi
            cmd=(verify)
            if [ -n "$RESTORE_TIME" ] ; then
                cmd+=(--time "$RESTORE_TIME")
            fi
            cmd+=(--path-to-restore "$CPATH" "$BACKUP_TARGET" "/${CPATH}")
            verify_run "$CPATH" "${cmd[@]}"
        done
    else
        cmd=(verify)
        if [ -n "$RESTORE_TIME" ] ; then
            cmd+=(--time "$RESTORE_TIME")
        fi
        for CDIR in $SOURCE ; do
            cmd+=(--include "$CDIR")
        done
        cmd+=(--exclude '**')
        cmd+=("$BACKUP_TARGET" "/")
        verify_run "" "${cmd[@]}"
    fi
    END="$(date '+%s')"
    TIME="$((END - START))"
    assert_files_compared "$TIME" "$END"
    prom_write "status" "verify" "$TIME"
    prom_write "time" "verify" "$END"
}

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

function restore() {
    cmd=(restore)
    if [ $# == 1 ] ; then
        cmd+=(--force "$BACKUP_TARGET" "$1")
    else
        cmd+=(--force --time "$1" "$BACKUP_TARGET" "$2")
    fi
    exec_dup "${cmd[@]}"
}

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

function usage() {
    cleanup
    echo "
  dupwrap - manage duplicity backup

  USAGE:

  dupwrap backup
  dupwrap backup_verify [-i path ...]
  dupwrap list [-t time]
  dupwrap verify [-t time] [-i path ...]
  dupwrap status
  dupwrap prune (old backups)
  dupwrap clean (failed backups)
  dupwrap restore [dest]
  dupwrap restore_file src [time] dest

  -i may be repeated and restricts verify to those paths rather than the
  profile's whole source tree. Paths are RELATIVE to the backup root, the
  same form restore_file takes -- 'tmp/test-data/readme.txt', not
  '/tmp/test-data/readme.txt'; spaces and unicode need no quoting beyond
  what your shell requires to pass one argument. Each path costs its own
  duplicity run, and each must also EXIST locally -- a path absent on both
  sides is refused, because duplicity would compare it and exit 0 having
  proved nothing. It is a sampling check: it proves the archive decrypts
  and those paths round-trip, not that every volume is readable.

"
}

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

while getopts "qvc:i:p:t:h" arg; do
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
        i)
            VERIFY_INCLUDE+=("$OPTARG")
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
    if [ "$ACTION" == "backup" ] || [ "$ACTION" == "backup_verify" ] ; then
        dbg "Executing ${ACTION} for all profiles"
        # Preserve an explicit verify scope across per-profile re-exec.
        declare -a fwd_include=()
        for CINC in "${VERIFY_INCLUDE[@]}" ; do
            fwd_include+=(-i "$CINC")
        done
        for p in "${DUPWRAP_CONF_PREFIX}/"*.conf ; do
            VERBOSE="$VERBOSE" QUIET="$QUIET" "$0" "$ACTION" -c "$p" "${fwd_include[@]}"
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
    # Capture sourced-script failure before set -e can abort without metrics.
    set +e
    # shellcheck disable=SC1090
    . "$CRED_SCRIPT"
    _cred_rc=$?
    set -e
    [ "$_cred_rc" -eq 0 ] || problems "CRED_SCRIPT failed (rc=${_cred_rc}): ${CRED_SCRIPT}"
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
elif [ "$ACTION" = "backup_verify" ]; then
    if [ -n "$PRE_SCRIPT" ] ; then
        $PRE_SCRIPT
    fi
    # -i narrows only the verify; backup always protects the full source tree.
    backup
    verify
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
