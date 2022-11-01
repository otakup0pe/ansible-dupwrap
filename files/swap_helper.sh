#!/usr/bin/env bash

set -e
if [ $# != 1 ] ; then
    echo "This script can be used to manage swap space for backups on low memory systems"
    echo "${0} pre|post"
    exit 1
fi

ACTION="$1"
if [ "$ACTION" != "pre" ] && [ "$ACTION" != "post" ] ; then
    echo "Action must be pre or post"
    exit 1
fi

if [ -z "$DUPWRAP_CONF" ] ; then
    echo "DUPWRAP_CONF is not set"
    exit 1
fi

# This script is meant to be invoked from dupwrap where
# the variable should already be set.
# shellcheck disable=SC1090
. "$DUPWRAP_CONF"

SWAPFILE="${HOME}/.cache/duplicity/swap"
if [ -n "$ARCHIVE_DIR" ] ; then
    SWAPFILE="${ARCHIVE_DIR}/swap"
fi
SWAPDIR=$(dirname "$SWAPFILE")
if [ ! -d "$SWAPDIR" ] ; then
    mkdir -p "$SWAPDIR"
fi
if [ "$ACTION" == "pre" ] ; then
    RAMS=$(free -m | grep 'Mem:' | awk '{print $2}')
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$RAMS"
    chmod 0600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"
    echo "Created ${RAMS}M worth of swap"
elif [ "$ACTION" == "post" ] ; then
    if [ -e "$SWAPFILE" ] ; then
        swapoff "$SWAPFILE"
        rm "$SWAPFILE"
        echo "Removed swap"
    fi
fi
