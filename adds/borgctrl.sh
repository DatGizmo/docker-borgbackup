#!/bin/bash

# this is the borgbackup command file. This file needs to be installed on the
# host and docker side.
#
# this targets currently supported:
# backup - start a docker container which does start the do_backup target of
#          this file
# shell - opens a shell for restore and controling job
# do_backup - target which started in the docker container and does the backup
# server - start a server container
#
# functions host_* executed before the docker container gets started
# functions docker_* executed at docker runtime

declare -r INIFILE="$HOME/.borgbackup.ini"
declare -r DOCKERCONTAINER="borgbackup:test"
declare -r INSTALLDIR=$(dirname "$(realpath ${BASH_SOURCE[0]})" )

usage() {
	echo "-+> usage ..."
}

# fasting app start a bit
ldconfig

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
declare -A SERVER
declare -A BACKUPS
declare -A BACKUPIDS

init_from_ini() {
	source $SHINI

	__shini_parsed () {
		case "${1}" in
			"GENERAL")
				[[ "$2" == "REPOSITORY" ]] && GENERAL[REPOSITORY]="$3"
				[[ "$2" == "SSHKEY" ]] && GENERAL[SSHKEY]="$3"
				[[ "$2" == "ENCRYPTION" ]] && GENERAL[ENCRYPTION]="$3"
				[[ "$2" == "SUDO" ]] && GENERAL[SUDO]="$3"
				[[ "$2" == "FOLDER" ]] && GENERAL[FOLDER]="$3"
				[[ "$2" == "FILECACHE" ]] && GENERAL[FILECACHE]="$3"
				[[ "$2" == "VERBOSE" ]] && GENERAL[VERBOSE]="$3"
				[[ "$2" == "STAT" ]] && GENERAL[STAT]="$3"
				[[ "$2" == "RESTOREDIR" ]] && GENERAL[RESTOREDIR]="$3"
				;;
			"SERVER")
				[[ "$2" == "REPOSITORYFOLDER" ]] && SERVER[REPOSITORYFOLDER]="${3}"
				[[ "$2" == "SSHPORT" ]] && SERVER[SSHPORT]="${3}"
				[[ "$2" == "SSHKEYCONF" ]] && SERVER[SSHKEYCONF]="${3}"
				[[ "$2" == "BACKGROUND" ]] && SERVER[BACKGROUND]="${3}"
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
			*)
				echo "-+> Section \"$1\" unknown"
				exit 1
				;;
		esac
	}
	shini_parse ${INIFILE}

	# error and default handling
	[[ -z "${GENERAL[FOLDER]}" ]] && GENERAL[FOLDER]="/STORAGE/BACKUP"
	[[ -z "${GENERAL[SSHKEY]}" ]] && echo "-+> sshkey is needed" && exit 1
	[[ ! -z "${GENERAL[VERBOSE]}" ]] && [[ "${GENERAL[VERBOSE]}" == "1" ]] && GENERAL[VERBOSE]="-v" || GENERAL[VERBOSE]=""
	[[ ! -z "${GENERAL[STAT]}" ]] && [[ "${GENERAL[STAT]}" == "1" ]] && GENERAL[STAT]="-s" || GENERAL[STAT]=""

	[[ -z "${GENERAL[REPOSITORY]}" ]] && echo "-+> ini file problem: GENERAL -> REPOSITORY not set" && exit 1
	tlatag="${GENERAL[REPOSITORY]:0:3}"
	[[ "${tlatag}" != "ssh" ]] && [[ "${tlatag}" != "fil" ]] && \
		echo "-+> ini file problem: GENERAL -> REPOSITORY should start with ssh: or file:" && exit 1
	arr=(${GENERAL[REPOSITORY]//:/ })
	[[ "${arr[0]}" == "file" ]] && GENERAL[FILESTORE]="${arr[1]}"

	if [[ ! -z "${SERVER[REPOSITORYFOLDER]}${SERVER[SSHPORT]}${SERVER[SSHKEYCONF]}" ]]; then
		[[ -z "${SERVER[REPOSITORYFOLDER]}" ]] && echo "-+> ini property SERVER -> REPOSITORYFOLDER should be set" && exit 1
		[[ -z "${SERVER[SSHPORT]}" ]] && echo "-+> ini property SERVER -> SSHPORT should be set" && exit 1
		[[ -z "${SERVER[SSHKEYCONF]}" ]] && echo "-+> ini property SERVER -> SSHKEYCONF should be set" && exit 1
	fi
	[[ ! -z "${SERVER[BACKGROUND]}" ]] && [[ "${SERVER[BACKGROUND]}" == "1" ]] && SERVER[BACKGROUND]="-d" || SERVER[BACKGROUND]="-ti"

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
	#dockerenv="${dockerenv} -v ${HOME}/.ssh/:/root/.ssh:ro"

	sshkey=$(echo ${GENERAL[SSHKEY]}*)
	for key in ${sshkey}; do
		sshkeybasename=$(basename ${key})
		dockerenv="${dockerenv} -v ${key}:/root/.ssh/${sshkeybasename}:ro"
	done

	[[ "${GENERAL[SUDO]}" == "1" ]] && sudo="sudo"
	[[ ! -z "${GENERAL[FILECACHE]}" ]] && dockerenv="${dockerenv} -v ${GENERAL[FILECACHE]}:/root/.cache/borg"
	[[ ! -z "${GENERAL[RESTOREDIR]}" ]] && dockerenv="${dockerenv} -v ${GENERAL[RESTOREDIR]}:/RESTORE"
	[[ ! -z "${GENERAL[ENCRYPTION]}" ]] && dockerenv="${dockerenv} -e BORG_PASSPHRASE=${GENERAL[ENCRYPTION]}"

	[[ ! -z "${GENERAL[FILESTORE]}" ]] && dockerenv="${dockerenv} -v ${GENERAL[FILESTORE]}:/STORAGE"

	for id in "${!BACKUPIDS[@]}"; do
		[[ ! -z "${BACKUPS[PATH${id}]}" ]] && dockerenv="${dockerenv} -v ${BACKUPS[PATH${id}]}:/BACKUP/${BACKUPS[PATH${id}]}"
	done
}

host_shell() {
	host_build_dockerenv_from_ini

	echo "-+> ${sudo} docker run -ti --rm --privileged ${dockerenv} ${DOCKERCONTAINER} do_shell"
	          ${sudo} docker run -ti --rm --privileged ${dockerenv} ${DOCKERCONTAINER} do_shell
}

docker_set_borg_repo() {
	init_from_ini

	source /borg-env/bin/activate

	[[ ! -z "${GENERAL[FILESTORE]}" ]] && GENERAL[REPOSITORY]="/STORAGE"

	# successful mount
	export BORG_REPO="${GENERAL[REPOSITORY]}//${GENERAL[FOLDER]}"
	encryption=""
	[[ ! -z "${GENERAL[ENCRYPTION]}" ]] && encryption="--encryption=repokey"

	echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config
	echo "CheckHostIP no" >> /etc/ssh/ssh_config
}

docker_do_shell() {
	docker_set_borg_repo

	# must be the last line
	/bin/bash --rcfile /borg-env/bin/activate
}

host_backup() {
	host_build_dockerenv_from_ini

	echo "-+> ${sudo} docker run --sig-proxy=false -ti --rm --privileged ${dockerenv} ${DOCKERCONTAINER} do_backup"
	          ${sudo} docker run --sig-proxy=false -ti --rm --privileged ${dockerenv} ${DOCKERCONTAINER} do_backup
}

docker_do_backup() {
	docker_set_borg_repo

	source /borg-env/bin/activate

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

host_server() {
	init_from_ini

	REPOSITORYFOLDER="${SERVER[REPOSITORYFOLDER]}"
	SSHKEYCONF="${SERVER[SSHKEYCONF]}"
	SSHPORT="${SERVER[SSHPORT]}"

	failed="0"
	[[ ! -d "${REPOSITORYFOLDER}" ]] && echo "-+> REPOSITORYFOLDER \"${REPOSITORYFOLDER}\" needs to be a directory and should exists" && failed="1"
	[[ ! -f "${SSHKEYCONF}" ]] && echo "-+> SSHKEYCONF \"${SSHKEYCONF}\" needs to be a file and should exists" && failed="1"

	[[ "${failed}" == "1" ]] && exit 1

	dockerenv="-v ${REPOSITORYFOLDER}:/STORAGE"
	dockerenv="${dockerenv} -v ${SSHKEYCONF}:/root/sshkeys.txt:ro"
	dockerenv="${dockerenv} -v ${HOME}/.borgbackup.ini:/root/.borgbackup.ini"
	dockerenv="${dockerenv} -e SSHPORT=${SSHPORT}"

	echo "-+> ${sudo} docker stop backupserver"
	          ${sudo} docker stop backupserver
	echo "-+> ${sudo} docker rm backupserver"
	          ${sudo} docker rm backupserver
	echo "-+> ${sudo} docker run ${SERVER[BACKGROUND]} --name=backupserver --privileged ${dockerenv} ${DOCKERCONTAINER} do_server"
	          ${sudo} docker run ${SERVER[BACKGROUND]} --name=backupserver --privileged ${dockerenv} ${DOCKERCONTAINER} do_server
}

docker_do_server() {
	# build authorized_keys file
	mkdir -p /root/.ssh
	:>/root/.ssh/authorized_keys
	while IFS='' read -r line || [[ -n "${line}" ]]; do
		echo "command=\"/borg-env/bin/borg serve --verbose --restrict-to-path /STORAGE\" ${line}" >> /root/.ssh/authorized_keys
	done < /root/sshkeys.txt

	# change port ...
	sed -i "s/Port 22/Port ${SSHPORT}/" /etc/ssh/sshd_config

	# start/stop of sshd via init script to configure all keys etc
	/etc/init.d/ssh start
	/etc/init.d/ssh stop

	ip addr show eth0

	/usr/sbin/sshd -D
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
	"server")
		host_server
		;;
	"do_server")
		docker_do_server
		;;
esac
exit 0
