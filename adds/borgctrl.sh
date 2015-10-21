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
# functions host_* executed before the docker container gets started
# functions docker_* executed at docker runtime

declare -r INIFILE="$HOME/.borgbackup.ini"
declare -r DOCKERCONTAINER="borgbackup:test"
declare -r INSTALLDIR=$(dirname "$(realpath ${BASH_SOURCE[0]})" )

usage() {
	echo "usage ..."
}

# check installation of shini
SHINI=""
if [[ -f ${INSTALLDIR}/../misc/shini/shini.sh ]]; then
	SHINI="${INSTALLDIR}/../misc/shini/shini.sh"
else
	if [[ -f /usr/bin/shini ]]; then
		SHINI=/usr/bin/shini
	else
		echo "NO /usr/bin/shini found, please copy shini.sh from https://github.com/wallyhall/shini to /usr/bin/"
		usage
		exit 1
	fi
fi

[[ -z "${1}" ]] && usage && exit 1
[[ ! -e "${INIFILE}" ]] && echo "No ${INIFILE} found" && usage && exit 1

# declare associative arrays
declare -A GENERAL
declare -A BACKUPS
declare -A BACKUPIDS

init_from_ini() {
	source $SHINI

	__shini_parsed () {
		case "${1}" in
			"GENERAL")
				[[ "$2" == "REPOSITORY" ]] && GENERAL[REPOSITORY]="$3"
				[[ "$2" == "SUDO" ]] && GENERAL[SUDO]="$3"
				[[ "$2" == "FOLDER" ]] && GENERAL[FOLDER]="$3"
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

	# default handling
	[[ -z "${GENERAL[FOLDER]}" ]] && GENERAL[FOLDER]="BACKUP"
}

host_shell() {
	local dockerenv=""
	local sudo=""

	init_from_ini

	dockerenv="-v ${HOME}/.borgbackup.ini:/root/.borgbackup.ini"
	dockerenv="${dockerenv} -v ${SSH_AUTH_SOCK}:/root/.ssh-agent -e SSH_AUTH_SOCK=/root/.ssh-agent"

	[[ "${GENERAL[SUDO]}" == "1" ]] && sudo="sudo"
	[[ ! -z "${GENERAL[ENV]}" ]] && dockerenv="${dockerenv} ${GENERAL[ENV]}"
	[[ ! -z "${GENERAL[FILECACHE]}" ]] && dockerenv="${dockerenv} -v ${GENERAL[FILECACHE]}:/root/.cache/borg"
	[[ ! -z "${GENERAL[RESTORE]}" ]] && dockerenv="${dockerenv} -v ${GENERAL[RESTORE]}:/RESTORE"

	for id in "${!BACKUPIDS[@]}"; do
		[[ ! -z "${BACKUPS[PATH${id}]}" ]] && dockerenv="${dockerenv} -v ${BACKUPS[PATH${id}]}:/BACKUP/${BACKUPS[PATH${id}]}"
	done

	echo "${sudo} docker run -ti --rm ${dockerenv} ${DOCKERCONTAINER} do_shell"
	${sudo} docker run -ti --rm --privileged ${dockerenv} ${DOCKERCONTAINER} do_shell
}

docker_do_shell() {
	init_from_ini

	docker_mount_repo

	# setup sshfs
	# must be the last line
	/bin/bash --rcfile /borg-env/bin/activate
}

docker_mount_repo() {
	init_from_ini

	sshfs "${GENERAL[REPOSITORY]}" /REPO -o CheckHostIP=no -o StrictHostKeyChecking=no
	if [[ "${?}" != "0" ]]; then
		# mounting was not successfull
		echo "mount of ${GENERAL[REPOSITORY]} to /REPO via sshfs was not successfull"
	else
		# successful mount
		export BORG_REPO="/REPO/${GENERAL[FOLDER]}"
		[[ ! -e "${BORG_REPO}" ]] && echo "init backupfolder" && borg init
	fi
}

host_backup() {
	:
}

docker_do_backup() {
	:
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

