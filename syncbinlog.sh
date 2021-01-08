#!/bin/bash

########### syncbinlog.sh #############
# Copyright 2019 Arda Beyazoglu
# MIT License
#
# A bash script that uses mysqlbinlog
# utility to syncronize binlog files
#######################################

# Write usage
usage() {
    echo -e "Usage: $(basename $0) [options]"
    echo -e "\tStarts live binlog sync using mysqlbinlog utility\n"
    echo -e "   --user=              username to login to mysql"
    echo -e "   --password=          password for the username"
    echo -e "   --host=              mysql host"
    echo -e "   --start-file=        start copying logs from this file"
    echo -e "   --backup-dir=        Backup destination directory (required)"
    echo -e "   --log-dir=           Log directory (defaults to '/var/log/syncbinlog')"
    echo -e "   --compress           Compress backuped binlog files"
    echo -e "   --compress-app=      Compression app (defaults to 'pigz'). Compression parameters can be given as well (e.g. pigz -p6 for 6 threaded compression)"
    echo -e "   --rotate=X           Rotate backup files for X days, 0 for no deletion (defaults to 0)"
    echo -e "   --verbose=           Write logs to stdout as well"
    exit 1
}

# Write log
log () {
    local level="INFO"
    if [[ -n $2 ]]; then
        level=$2
    fi
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')][${level}] $1"
    echo "${msg}" >> "${LOG_DIR}/status.log"

    if [[ ${VERBOSE} == true ]]; then
        echo "${msg}"
    fi
}

# Parse configuration parameters
MYSQL_OPTIONS=""
parse_config() {
    for arg in ${ARGS}
    do
        case ${arg} in
            --user=*)
            MYSQL_OPTIONS="${MYSQL_OPTIONS} --user=${arg#*=}"
            ;;
            --password=*)
            MYSQL_OPTIONS="${MYSQL_OPTIONS} --password=${arg#*=}"
            ;;
            --host=*)
            MYSQL_OPTIONS="${MYSQL_OPTIONS} --host=${arg#*=}"
            ;;
            --start-file=*)
            BINLOG_FIRST_SYNC_FILE="${arg#*=}"
            ;;
            --log-dir=*)
            LOG_DIR="${arg#*=}"
            ;;
            --backup-dir=*)
            BACKUP_DIR="${arg#*=}"
            ;;
            --compress)
            COMPRESS=true
            ;;
            --compress-app=*)
            COMPRESS_APP="${arg#*=}"
            ;;
            --rotate=*)
            ROTATE_DAYS="${arg#*=}"
            ;;
            --verbose)
            VERBOSE=true
            ;;
            --help)
            usage
            ;;
            *)
            # unknown option
            usage
            ;;
        esac
    done
}

# Compress backup files that are currently open
compress_files() {
    # find last modified binlog backup file
    LAST_MODIFIED_BINLOG_FILE=$(find ${BACKUP_DIR} -type f -printf "%T@ %p\n" | sort -n | tail -1 | awk '{print $2}' | grep -P ".+\.[0-9]+$")
    LAST_MODIFIED_BINLOG_FILE=$(basename ${LAST_MODIFIED_BINLOG_FILE})

    # find all binlog backup files sorted by modification date
    SORTED_BINLOG_FILES=$(find ${BACKUP_DIR} -type f -printf "%T@ %p\n" | sort -n | awk '{print $2}' | grep -v ".gz")

    for filename in ${SORTED_BINLOG_FILES}
    do
        # check if file exists
        [[ -f "${filename}" ]] || break

        # break on last modified backup file, because its not completely written yet
        [[ `basename ${filename}` == "${LAST_MODIFIED_BINLOG_FILE}" ]] && break

        log "Compressing ${filename}"
        ${COMPRESS_APP} --force ${filename} > "${LOG_DIR}/status.log"
        log "Compressed ${filename}"
    done
}

# Rotate older backups
rotate_files() {
    if [ "{ROTATE_DAYS}" == "0" ]; then
        return 0
    fi

    # find binlog backup files older than rotation period
    ROTATED_FILES=$(find ${BACKUP_DIR} -type f -mtime +${ROTATE_DAYS})
    for filename in ${ROTATED_FILES}
    do
        log "Rotation: deleting ${filename}"
        rm ${filename}
    done
}

# Exit safely on signal
die() {
    log "Exit signal caught!"
    log "Stopping child processes before exit"
    trap - SIGINT SIGTERM # clear the listener
    kill -- -$$ # Sends SIGTERM to child/sub processes
    if [[ ! -z ${APP_PID} ]]; then
        log "Killing mysqlbinlog process"
        kill ${APP_PID}
    fi
}

# listen to the process signals
trap die SIGINT SIGTERM

# Default configuration parameters
BACKUP_DIR=""
LOG_DIR=/var/log/syncbinlog
COMPRESS=false
COMPRESS_APP="pigz -p$(($(nproc) - 1))"
ROTATE_DAYS=0
VERBOSE=false

ARGS="$@"
parse_config

if [[ -z ${BACKUP_DIR} ]]; then
    echo "ERROR: Please, specify a destination directory for backups using --backup-dir parameter."
    usage
    exit 1
fi

APP_PID=0
BACKUP_DIR=$(realpath ${BACKUP_DIR})
LOG_DIR=$(realpath ${LOG_DIR})

mkdir -p ${LOG_DIR} || exit 1
mkdir -p ${BACKUP_DIR} || exit 1
cd ${BACKUP_DIR} || exit 1

log "Initializing binlog sync"
log "Backup destination: $BACKUP_DIR"
log "Log destination: $LOG_DIR"

${COMPRESS} == true && log "Compression enabled"

while :
do
    RUNNING=false

    # check pid to see if mysqlbinlog is running
    if [[ "$APP_PID" -gt "0" ]]; then
        # check process name to ensure it is mysqlbinlog pid
        APP_NAME=$(ps -p ${APP_PID} -o cmd= | awk '{ print $1 }')
        if [[ ${APP_NAME} == "mysqlbinlog" ]]; then
            RUNNING=true
        fi
    fi

    if [[ ${RUNNING} == true ]]; then
        # check older backups to compress
        ${COMPRESS} == true && compress_files

        # check file timestamps to apply rotation
        rotate_files

        # sleep and continue
        sleep 30
        continue
    fi

    # Check last backup file to continue from (2> /dev/null suppresses error output)
    LAST_BACKUP_FILE=`ls -1 ${BACKUP_DIR}/* 2> /dev/null | tail -n 1`

    if [[ -z ${LAST_BACKUP_FILE} ]]; then
        log "No backup file found"

        # If there is no backup yet, use the file provided in the args
        if [[ -z "${BINLOG_FIRST_SYNC_FILE}" ]]; then
            echo "ERROR: Please, specify both start file and position for binlogs."
            exit 1
        fi

        log "Starting to copy from ${BINLOG_FIRST_SYNC_FILE}"
    else
        # If mysqlbinlog crashes/exits in the middle of execution, we cant know the last position reliably.
        # Thats why restart syncing from the beginning of the same binlog file
        LAST_BACKUP_FILE=$(basename ${LAST_BACKUP_FILE})
        log "Last used backup file is $LAST_BACKUP_FILE"

        # CAUTION:
        # If the last backup file is too old, the relevant binlog file might not exist anymore
        # In this case, there will be a gap in binlog backups

        BINLOG_FIRST_SYNC_FILE=`basename "${LAST_BACKUP_FILE}"`
    fi

    log "Starting live binlog backup from ${BINLOG_FIRST_SYNC_FILE}"

    mysqlbinlog ${MYSQL_OPTIONS} \
        --raw --read-from-remote-server --stop-never \
        --verify-binlog-checksum \
        --result-file='' \
        ${BINLOG_FIRST_SYNC_FILE} >> "${LOG_DIR}/status.log" & APP_PID=$!

    log "mysqlbinlog PID=$APP_PID"

done
