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
	echo "-+> usage ..."
}

# check installation of shini
SHINI=""
if [[ -f ${INSTALLDIR}/../misc/shini/shini.sh ]]; then
	SHINI="${INSTALLDIR}/../misc/shini/shini.sh"
else
	if [[ -f /usr/bin/shini ]]; then
		SHINI=/usr/bin/shini
	else
		echo "-+> NO /usr/bin/shini found, please copy shini.sh from https://github.com/wallyhall/shini to /usr/bin/"
		usage
		exit 1
	fi
fi

[[ -z "${1}" ]] && usage && exit 1
[[ ! -e "${INIFILE}" ]] && echo "-+> No ${INIFILE} found" && usage && exit 1

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
				[[ "$2" == "ENCRYPTION" ]] && GENERAL[ENCRYPTION]="$3"
				[[ "$2" == "SUDO" ]] && GENERAL[SUDO]="$3"
				[[ "$2" == "FOLDER" ]] && GENERAL[FOLDER]="$3"
				[[ "$2" == "FILECACHE" ]] && GENERAL[FILECACHE]="$3"
				[[ "$2" == "VERBOSE" ]] && GENERAL[VERBOSE]="$3"
				[[ "$2" == "STAT" ]] && GENERAL[STAT]="$3"
				[[ "$2" == "RESTOREDIR" ]] && GENERAL[RESTOREDIR]="$3"
				;;
			"BACKUP"*)
				id="${1//BACKUP/}"
				BACKUPIDS["${id}"]=1
				[[ "$2" == "PATH" ]] && BACKUPS[PATH${id}]="${3}"
				[[ "$2" == "CHUNKER" ]] && BACKUPS[CHUNKER${id}]="${3}"
				[[ "$2" == "COMPRESSION" ]] && BACKUPS[COMPRESSION${id}]="${3}"
				[[ "$2" == "KEEPWITHIN" ]] && BACKUPS[KEEPWITHIN${id}]="${3}"
				[[ "$2" == "PRUNEHOURLY" ]] && BACKUPS[PRUNEHOURLY${id}]="$3"
				[[ "$2" == "PRUNEDAILY" ]] && BACKUPS[PRUNEDAILY${id}]="$3"
				[[ "$2" == "PRUNEWEEKLY" ]] && BACKUPS[PRUNEWEEKLY${id}]="$3"
				[[ "$2" == "PRUNEMONTHLY" ]] && BACKUPS[PRUNEMONTHLY${id}]="$3"
				[[ "$2" == "PRUNEYEARLY" ]] && BACKUPS[PRUNEYEARLY${id}]="$3"
				if [[ "$2" == "EXCLUDE" ]]; then
					# Appending of exclude patterns
					local excludepath="${3}"
					[[ "${excludepath:0:1}" == "/" ]] && excludepath="/BACKUP/${excludepath}"
					BACKUPS[EXCLUDE${id}]="${BACKUPS[EXCLUDE${id}]} ${excludepath}"
				fi
				;;
		esac
	}
	shini_parse ${INIFILE}

	# error and default handling
	[[ -z "${GENERAL[FOLDER]}" ]] && GENERAL[FOLDER]="BACKUP"
	[[ ! -z "${GENERAL[VERBOSE]}" ]] && [[ "${GENERAL[VERBOSE]}" == "1" ]] && GENERAL[VERBOSE]="-v" || GENERAL[VERBOSE]=""
	[[ ! -z "${GENERAL[STAT]}" ]] && [[ "${GENERAL[STAT]}" == "1" ]] && GENERAL[STAT]="-s" || GENERAL[STAT]=""

	failed="0"
	for id in "${!BACKUPIDS[@]}"; do
		[[ -z "${BACKUPS[PATH${id}]}" ]] && echo "-+> ini-file problem: PATH-entry for BACKUP${id} not provided" && failed="1"
		[[ -z "${BACKUPS[COMPRESSION${id}]}" ]] && BACKUPS[COMPRESSION${id}]="-C none" || BACKUPS[COMPRESSION${id}]="-C ${BACKUPS[COMPRESSION${id}]}"
		[[ ! -z "${BACKUPS[CHUNKER${id}]}" ]] && BACKUPS[CHUNKER${id}]="--chunker-params ${BACKUPS[CHUNKER${id}]}"
	done
	[[ "${failed}" == "1" ]] && exit 1
}

host_build_dockerenv_from_ini() {
	init_from_ini

	dockerenv="-v ${HOME}/.borgbackup.ini:/root/.borgbackup.ini"
	dockerenv="${dockerenv} -v ${SSH_AUTH_SOCK}:/root/.ssh-agent -e SSH_AUTH_SOCK=/root/.ssh-agent"

	[[ "${GENERAL[SUDO]}" == "1" ]] && sudo="sudo"
	[[ ! -z "${GENERAL[FILECACHE]}" ]] && dockerenv="${dockerenv} -v ${GENERAL[FILECACHE]}:/root/.cache/borg"
	[[ ! -z "${GENERAL[RESTOREDIR]}" ]] && dockerenv="${dockerenv} -v ${GENERAL[RESTOREDIR]}:/RESTORE"
	[[ ! -z "${GENERAL[ENCRYPTION]}" ]] && dockerenv="${dockerenv} -e BORG_PASSPHRASE=${GENERAL[ENCRYPTION]}"

	for id in "${!BACKUPIDS[@]}"; do
		[[ ! -z "${BACKUPS[PATH${id}]}" ]] && dockerenv="${dockerenv} -v ${BACKUPS[PATH${id}]}:/BACKUP/${BACKUPS[PATH${id}]}"
	done
}

host_shell() {
	host_build_dockerenv_from_ini

	echo "-+> ${sudo} docker run -ti --rm --privileged ${dockerenv} ${DOCKERCONTAINER} do_shell"
	          ${sudo} docker run -ti --rm --privileged ${dockerenv} ${DOCKERCONTAINER} do_shell
}

docker_mount_repo() {
	init_from_ini

	source /borg-env/bin/activate

	mount_sshfs_failed="1"

	sshfs "${GENERAL[REPOSITORY]}" /REPO -o CheckHostIP=no -o StrictHostKeyChecking=no -o modules=iconv,from_code=UTF-8,to_code=UTF-8
	if [[ "${?}" != "0" ]]; then
		# mounting was not successfull
		echo "-+> mount of ${GENERAL[REPOSITORY]} to /REPO via sshfs was not successfull"
	else
		# successful mount
		export BORG_REPO="/REPO/${GENERAL[FOLDER]}"
		encryption=""
		[[ ! -z "${GENERAL[ENCRYPTION]}" ]] && encryption="--encryption=repokey"
		[[ ! -e "${BORG_REPO}" ]] && echo "-+> init backupfolder" && borg init "${encryption}"
		mount_sshfs_failed="0"
	fi
}

docker_do_shell() {
	docker_mount_repo

	if docker_check_locked_repo; then
		echo "-+> your repository is locked: ${BORG_REPO}/lock.exclusive"
		echo "-+> Check noone is accessing this repo and removing the"
		echo "-+> lock via 'rm -rf ${BORG_REPO}/lock.exclusive'"
	fi

	# must be the last line
	/bin/bash --rcfile /borg-env/bin/activate
}

host_backup() {
	host_build_dockerenv_from_ini

	${sudo} docker run --sig-proxy=false -ti --rm --privileged ${dockerenv} ${DOCKERCONTAINER} do_backup
}

docker_check_locked_repo() {
	[[ -e "${BORG_REPO}/lock.exclusive" ]] && return 0

	return 1
}

docker_do_backup() {
	docker_mount_repo

	if [[ "${mount_sshfs_failed}" == "1" ]]; then
		echo "-+> mount was not successful - please review your setup"
		exit 1
	fi

	source /borg-env/bin/activate

	if docker_check_locked_repo; then
		echo "-+> your repository is locked: ${BORG_REPO}/lock.exclusive"
		echo "-+> Please start a shell, check noone is accessing this"
		echo "-+> repo and removing this via"
		echo "-+>      rm -rf ${BORG_REPO}/lock.exclusive"
		exit 1
	fi

	DATE="$(date --rfc-3339=seconds)"
	DATE="${DATE//[^[:alnum:]]/}"
	for id in "${!BACKUPIDS[@]}"; do
		echo ""
		echo "-+> BACKUP for ${id} ..."
		borgpath="${BACKUPS[PATH${id}]}"
		borgarchivebase="${borgpath//[^[:alnum:]]/}"
		borgarchive="::${borgarchivebase}-${DATE}"
		borgchunk="${BACKUPS[CHUNKER${id}]}"
		borgcompress="${BACKUPS[COMPRESSION${id}]}"
		borgexclude=""
		for path in $(echo ${BACKUPS[EXCLUDE${id}]}); do
			borgexclude="${borgexclude} -e ${path}"
		done

		echo "-+> borg create ${GENERAL[STAT]} ${GENERAL[VERBOSE]} ${borgcompress} ${borgchunk} ${borgexclude} ${borgarchive} /BACKUP/${borgpath}"
		          borg create ${GENERAL[STAT]} ${GENERAL[VERBOSE]} ${borgcompress} ${borgchunk} ${borgexclude} ${borgarchive} /BACKUP/${borgpath}

		borgpruneparam=""
		[[ ! -z "${BACKUPS[PRUNEHOURLY${id}]}" ]] && borgpruneparam="-H ${BACKUPS[PRUNEHOURLY${id}]}"
		[[ ! -z "${BACKUPS[PRUNEDAILY${id}]}" ]] && borgpruneparam="-d ${BACKUPS[PRUNEDAILY${id}]}"
		[[ ! -z "${BACKUPS[PRUNEWEEKLY${id}]}" ]] && borgpruneparam="-w ${BACKUPS[PRUNEWEEKLY${id}]}"
		[[ ! -z "${BACKUPS[PRUNEMONTHLY${id}]}" ]] && borgpruneparam="-m ${BACKUPS[PRUNEMONTHLY${id}]}"
		[[ ! -z "${BACKUPS[PRUNEYEARLY${id}]}" ]] && borgpruneparam="-y ${BACKUPS[PRUNEYEARLY${id}]}"
		[[ ! -z "${BACKUPS[KEEPWITHIN${id}]}" ]] && borgpruneparam="--keep-within ${BACKUPS[KEEPWITHIN${id}]}"

		if [[ ! -z "${borgpruneparam}" ]]; then
			echo "-+> PRUNE  for ${id} ..."
			echo "-+> borg prune -p ${borgarchivebase} ${GENERAL[STAT]} ${GENERAL[VERBOSE]} ${borgpruneparam}"
			          borg prune -p ${borgarchivebase} ${GENERAL[STAT]} ${GENERAL[VERBOSE]} ${borgpruneparam}
		fi
	done
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

