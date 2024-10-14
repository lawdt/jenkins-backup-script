#!/bin/bash -xe
#
# Jenkins backup script
# https://github.com/sue445/jenkins-backup-script
#
# Usage: ./jenkins-backup.sh -j /path/to/jenkins_home -d /path/to/backup/archive.tar.zst [-p] [-k number_of_backups]

readonly CUR_DIR=$(cd $(dirname "${BASH_SOURCE:-$0}"); pwd)
readonly TMP_DIR="${CUR_DIR}/tmp"
readonly ARC_NAME="jenkins-backup"
readonly ARC_DIR="${TMP_DIR}/${ARC_NAME}"
readonly TMP_TAR_NAME="${TMP_DIR}/archive.tar.zst"

JENKINS_HOME=""
DEST_FILE=""
COPY_PLUGINS=false  # Default: plugin backup disabled
KEEP_BACKUPS=0      # Default: keep all backups

function usage() {
  echo "Usage: $(basename "$0") -j /path/to/jenkins_home -d /path/to/backup/archive.tar.zst [-p] [-k number_of_backups]"
  echo
  echo "Options:"
  echo "  -j   Path to Jenkins Home directory."
  echo "  -d   Path to backup archive."
  echo "  -p   Include plugins in the backup."
  echo "  -k   Number of backups to keep. Older backups will be deleted."
  exit 1
}

# Parse arguments using getopts
while getopts "j:d:pk:" opt; do
  case ${opt} in
    j)
      JENKINS_HOME="$OPTARG"
      ;;
    d)
      DEST_FILE="$OPTARG"
      ;;
    p)
      COPY_PLUGINS=true
      ;;
    k)
      KEEP_BACKUPS="$OPTARG"
      ;;
    *)
      usage
      ;;
  esac
done

# Check if mandatory parameters are set
if [[ -z "${JENKINS_HOME}" || -z "${DEST_FILE}" ]]; then
  usage
fi

# Function to remove old backups using find
function cleanup_old_backups() {
  local backup_dir
  backup_dir=$(dirname "${DEST_FILE}")

  # Find and sort backup files by modification time, limit to files older than the last KEEP_BACKUPS
  local backups_to_remove
  backups_to_remove=$(find "${backup_dir}" -maxdepth 1 -name "*.tar.zst" -type f -printf "%T@ %p\n" | sort -n | head -n -"${KEEP_BACKUPS}" | cut -d' ' -f2-)

  if [ -n "${backups_to_remove}" ]; then
    echo "Removing old backups:"
    echo "${backups_to_remove}"
    echo "${backups_to_remove}" | xargs rm -f
  fi
}

function backup_jobs() {
  local run_in_path="$1"
  local rel_depth=${run_in_path#${JENKINS_HOME}/jobs/}

  if [ -d "${run_in_path}" ]; then
    cd "${run_in_path}"

    find . -maxdepth 1 -type d | while read -r job_name; do
      [ "${job_name}" = "." ] && continue
      [ "${job_name}" = ".." ] && continue
      mkdir -p "${ARC_DIR}/jobs/${rel_depth}/${job_name}/"

      # Copy configuration files
      find "${JENKINS_HOME}/jobs/${rel_depth}/${job_name}/" -maxdepth 1 \( -name "*.xml" -o -name "nextBuildNumber" \) -print0 | xargs -0 -I {} cp {} "${ARC_DIR}/jobs/${rel_depth}/${job_name}/"
      
      # Copy builds directory excluding artifacts
      if [ -d "${JENKINS_HOME}/jobs/${rel_depth}/${job_name}/builds" ]; then
        mkdir -p "${ARC_DIR}/jobs/${rel_depth}/${job_name}/builds"
        rsync -a --exclude='archive/**' "${JENKINS_HOME}/jobs/${rel_depth}/${job_name}/builds/" "${ARC_DIR}/jobs/${rel_depth}/${job_name}/builds/"
      fi
      
      # Recursively backup nested jobs if it's a folder
      if [ -f "${JENKINS_HOME}/jobs/${rel_depth}/${job_name}/config.xml" ] && [ "$(grep -c "com.cloudbees.hudson.plugins.folder.Folder" "${JENKINS_HOME}/jobs/${rel_depth}/${job_name}/config.xml")" -ge 1 ]; then
        backup_jobs "${JENKINS_HOME}/jobs/${rel_depth}/${job_name}/jobs"
      fi
    done
    cd -
  fi
}

function cleanup() {
  rm -rf "${ARC_DIR}"
}

function main() {
  rm -rf "${ARC_DIR}" "${TMP_TAR_NAME}"
  for fold in jobs users secrets nodes plugins; do
    mkdir -p "${ARC_DIR}/${fold}"
  done

  cp "${JENKINS_HOME}/"*.xml "${ARC_DIR}"

  # Copy jks files if they exist
  jks_count=$(find ${JENKINS_HOME} -maxdepth 1 -type f -name '*.jks' | wc -l)
  if [ ${jks_count} -ne 0 ]; then
    cp "${JENKINS_HOME}/"*.jks "${ARC_DIR}/"
  fi

  if [ "$(ls -A ${JENKINS_HOME}/users/)" ]; then
    cp -R "${JENKINS_HOME}/users/"* "${ARC_DIR}/users"
  fi

  if [ "$(ls -A ${JENKINS_HOME}/secrets/)" ]; then
    cp -R "${JENKINS_HOME}/secrets/"* "${ARC_DIR}/secrets"
  fi

  if [ "$(ls -A ${JENKINS_HOME}/nodes/)" ]; then
    cp -R "${JENKINS_HOME}/nodes/"* "${ARC_DIR}/nodes"
  fi

  if [ "$(ls -A ${JENKINS_HOME}/jobs/)" ]; then
    backup_jobs "${JENKINS_HOME}/jobs/"
  fi

  # Copy plugins if specified
  if [ "${COPY_PLUGINS}" = "true" ]; then
    if [ "$(ls -A ${JENKINS_HOME}/plugins/)" ]; then
      cp -R "${JENKINS_HOME}/plugins/"* "${ARC_DIR}/plugins"
    fi
  fi

  # Create archive using tar and zstd compression
  cd "${TMP_DIR}"
  tar -I zstd -cf "${TMP_TAR_NAME}" "${ARC_NAME}/"
  cd -

  mv -f "${TMP_TAR_NAME}" "${DEST_FILE}"

  # Clean up old backups if necessary
  cleanup_old_backups

  cleanup

  exit 0
}

# Run the main function and ensure cleanup on exit
trap cleanup EXIT
main