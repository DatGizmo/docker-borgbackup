#!/bin/bash

# this is the borgbackup command file. This file needs to be installed on the
# host and docker side.
#
# this targets currently supported:
# backup - start a docker container which does start the do_backup target of
#          this file
# shell - opens a shell for restore and controling job
# do_backup - target which started in the docker container and does the backup
#

declare -r INIFILE="$HOME/.borgbackup.ini"
declare -r DOCKERCONTAINER="borgbackup:test"

usage() {
	echo "usage ..."
}

[[ -z "${1}" ]] && usage && exit 1
[[ ! -e "${INIFILE}" ]] && echo "No ${INIFILE} found" && usage && exit 1

# declare associative arrays
declare -A GENERAL
declare -A BACKUPS
declare -A BACKUPIDS

init_from_ini() {
	source /usr/bin/shini

	__shini_parsed () {
		case "${1}" in
			"GENERAL")
				[[ "$2" == "REPOSITORY" ]] && GENERAL[REPOSITORY]="$3"
				[[ "$2" == "SSHKEY" ]] && GENERAL[SSHKEY]="$3"
				[[ "$2" == "SUDO" ]] && GENERAL[SUDO]="$3"
				[[ "$2" == "FILECACHE" ]] && GENERAL[FILECACHE]="$3"
				[[ "$2" == "VERBOSE" ]] && GENERAL[VERBOSE]="$3"
				[[ "$2" == "RESTOREDIR" ]] && GENERAL[RESTOREDIR]="$3"
				if [[ "$2" == "ENV" ]]; then
					GENERAL[ENV]="${GENERAL[ENV]} -e $3"
				fi
				;;
			"BACKUP"*)
				id="${1//BACKUP/}"
				BACKUPIDS["${id}"]=1
				[[ "$2" == "PATH" ]] && BACKUPS[PATH${id}]="${3}"
				[[ "$2" == "CHUNKER" ]] && BACKUPS[CHUNKER${id}]="${3}"
				[[ "$2" == "COMPRESSION" ]] && BACKUPS[COMPRESSION${id}]="${3}"
				[[ "$2" == "KEEPWITHIN" ]] && BACKUPS[KEEPWITHIN${id}]="${3}"
				if [[ "$2" == "EXCLUDE" ]]; then
					# Appending of exclude patterns
					BACKUPS[EXCLUDE${id}]="${BACKUPS[EXCLUDE${id}]} ${3}"
				fi
				;;
		esac
	}

	shini_parse ${INIFILE}
}

host_backup() {
	:
}

host_shell() {
	local dockerenv=""
	local sudo=""

	init_from_ini

	dockerenv="-v ${HOME}/.borgbackup.ini:/root/.borgbackup.ini"

	[[ "${GENERAL[SUDO]}" == "1" ]] && sudo="sudo"
	[[ ! -z "${GENERAL[ENV]}" ]] && dockerenv="${dockerenv} ${GENERAL[ENV]}"
	[[ ! -z "${GENERAL[FILECACHE]}" ]] && dockerenv="${dockerenv} -v ${GENERAL[FILECACHE]}:/root/.cache/borg"
	[[ ! -z "${GENERAL[SSHKEY]}" ]] && dockerenv="${dockerenv} -v ${GENERAL[SSHKEY]}:/root/.ssh/id_rsa"
	[[ ! -z "${GENERAL[RESTORE]}" ]] && dockerenv="${dockerenv} -v ${GENERAL[RESTORE]}:/RESTORE"

	for id in "${!BACKUPIDS[@]}"; do
		[[ ! -z "${BACKUPS[PATH${id}]}" ]] && dockerenv="${dockerenv} -v ${BACKUPS[PATH${id}]}:/BACKUP/${BACKUPS[PATH${id}]}"
	done

	echo "${sudo} docker run -ti --rm ${dockerenv} ${DOCKERCONTAINER} do_shell"
	${sudo} docker run -ti --rm --privileged ${dockerenv} ${DOCKERCONTAINER} do_shell
}

docker_do_shell() {
	exec /bin/bash --rcfile /borg-env/bin/activate
}

docker_do_backup() {
	source /borg-env/bin/activate

	SCRIPTVERSION=1

	INIFILE=/B/borg-backup.ini
	BACKUPREPO=""
	BACKUPNAME=""
	DATEAPPEND=""
	DATEFORMAT=""
	EXCLUDE=""
	PRUNE="0"
	PRUNEHOUR=""
	PRUNEDAY=""
	PRUNEWEEK=""
	PRUNEMONTH=""
	PRUNEYEAR=""
	VERSION=0
	VERBOSE=0

	__shini_parsed () {
		case "${1}" in
			"REPO")
				[[ "${2}" == "backuprepo" ]] && export BACKUPREPO="${3}"
				[[ "${2}" == "backupname" ]] && export BACKUPNAME="${3}"
				[[ "${2}" == "dateappend" ]] && export DATEAPPEND="${3}"
				[[ "${2}" == "dateformat" ]] && export DATEFORMAT="${3}"
				;;

			"MISC")
				[[ "${2}" == "version" ]] && export VERSION=${3}
				[[ "${2}" == "verbose" ]] && export VERBOSE=${3}
				;;

			"EXCLUDE")
				pattern="${3}"
				[[ "${pattern:0:1}" == "/" ]] && pattern="/B${pattern}"
				export EXCLUDE="${EXCLUDE} --exclude ${pattern}"
				;;

			"PRUNE")
				[[ "${2}" == "enable" ]] && export PRUNE="1"
				[[ "${2}" == "hourly" ]] && export PRUNEHOUR="--keep-hourly ${3}"
				[[ "${2}" == "daily" ]] && export PRUNEDAY="--keep-daily ${3}"
				[[ "${2}" == "weekly" ]] && export PRUNEWEEK="--keep-weekly ${3}"
				[[ "${2}" == "monthly" ]] && export PRUNEMONTH="--keep-monthly ${3}"
				[[ "${2}" == "yearly" ]] && export PRUNEYEAR="--keep-yearly ${3}"
				;;

			*)
				echo "inifile problem: \$1=${1}, \$2=${2}, \$3=${3} unknown"
				;;
		esac
	}

	if [[ "$1" == "mybackup" ]]; then

		[[ ! -e ${INIFILE} ]] && echo "No inifile ${INIFILE}, exited" && exit 1

		source /usr/bin/shini

		shini_parse ${INIFILE}

		[[ "${SCRIPTVERSION}" != "${VERSION}" ]] && echo "scriptversion ${SCRIPTVERSION} not eqal with inifile version ${VERSION}" && exit 1

		[[ -z "${BACKUPREPO}" ]] && echo "inifile problem: no 'backuprepo' entry" && exit
		[[ -z "${BACKUPNAME}" ]] && echo "inifile problem: no 'backupname' entry" && exit

		[[ "${VERBOSE}" == "1" ]] && VERBOSE="--progress" || VERBOSE=""

		[[ -z "${DATEFORMAT}" ]] && export DATEFORMAT="+%Y-%m-%d"
		BACKUPDATE=$(date ${DATEFORMAT})

		backupname="${BACKUPNAME}"
		[[ ! -z "${DATEAPPEND}" ]] && backupname="${backupname}-${BACKUPDATE}"

		backuppathes=""
		backupdir="/backupdir"

		for i in /B/*
		do
			backuppathes="${backuppathes} ${i}"
		done

		[[ ! -e ${backupdir}/${BACKUPREPO} ]] && borg init ${backupdir}/${BACKUPREPO}

		echo ":: " borg create ${VERBOSE} --stats \
			${backupdir}/${BACKUPREPO}::${backupname} \
			${backuppathes} \
			${EXCLUDE}
		borg create ${VERBOSE} --stats \
			${backupdir}/${BACKUPREPO}::${backupname} \
			${backuppathes} \
			${EXCLUDE}

		if [[ "${PRUNE}" == "1" ]]; then
			echo ":: " borg prune --stats -v ${backupdir}/${BACKUPREPO} \
				${PRUNEDAY} \
				${PRUNEWEEK} \
				${PRUNEMONTH}
			borg prune --stats -v ${backupdir}/${BACKUPREPO} \
				${PRUNEHOUR} \
				${PRUNEDAY} \
				${PRUNEWEEK} \
				${PRUNEMONTH} \
				${PRUNEYEAR}
		fi

		exit 0
	fi

	borg $*
}

case "${1}" in
	"backup")
		host_backup
		;;
	"do_backup")
		docker_do_backup
		;;
	"shell")
		host_shell
		;;
	"do_shell")
		docker_do_shell
		;;
esac

