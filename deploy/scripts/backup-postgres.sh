#!/usr/bin/env bash

set -Eeuo pipefail

readonly BACKUP_DIR='/var/backups/ferrydo/postgres'
readonly CONTAINER_NAME='ferrydo-postgres'
readonly RETENTION_DAYS='14'

if [[ -L "${BACKUP_DIR}" ]]; then
  echo "Refusing to use symlinked backup directory: ${BACKUP_DIR}" >&2
  exit 1
fi

install -d -m 0700 "${BACKUP_DIR}"

resolved_backup_dir="$(realpath -e -- "${BACKUP_DIR}")"
if [[ "${resolved_backup_dir}" != "${BACKUP_DIR}" ]]; then
  echo "Unexpected backup directory: ${resolved_backup_dir}" >&2
  exit 1
fi

if [[ "$(docker inspect --format '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null)" != 'true' ]]; then
  echo "PostgreSQL container is not running: ${CONTAINER_NAME}" >&2
  exit 1
fi

db_user="$(docker exec "${CONTAINER_NAME}" printenv POSTGRES_USER)"
db_name="$(docker exec "${CONTAINER_NAME}" printenv POSTGRES_DB)"

if [[ ! "${db_user}" =~ ^[A-Za-z0-9_]+$ ]] || [[ ! "${db_name}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo 'PostgreSQL user or database name contains unexpected characters.' >&2
  exit 1
fi

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
final_path="${BACKUP_DIR}/ferrydo-${timestamp}.dump"
temporary_path="$(mktemp --tmpdir="${BACKUP_DIR}" ".ferrydo-${timestamp}.XXXXXX.dump")"

cleanup() {
  if [[ -n "${temporary_path:-}" && -f "${temporary_path}" ]]; then
    rm -f -- "${temporary_path}"
  fi
}
trap cleanup EXIT

docker exec "${CONTAINER_NAME}" \
  pg_dump \
  --username="${db_user}" \
  --dbname="${db_name}" \
  --format=custom \
  --no-owner \
  --no-privileges > "${temporary_path}"

if [[ ! -s "${temporary_path}" ]]; then
  echo 'PostgreSQL backup is empty.' >&2
  exit 1
fi

docker exec -i "${CONTAINER_NAME}" pg_restore --list < "${temporary_path}" >/dev/null

chmod 0600 "${temporary_path}"
mv -- "${temporary_path}" "${final_path}"
temporary_path=''

mapfile -d '' expired_backups < <(
  find -P "${BACKUP_DIR}" \
    -maxdepth 1 \
    -type f \
    -name 'ferrydo-*.dump' \
    -mtime "+${RETENTION_DAYS}" \
    -print0
)

for expired_backup in "${expired_backups[@]:-}"; do
  [[ -n "${expired_backup}" ]] || continue
  resolved_expired_backup="$(realpath -e -- "${expired_backup}")"
  case "${resolved_expired_backup}" in
    "${BACKUP_DIR}"/ferrydo-*.dump)
      rm -- "${resolved_expired_backup}"
      ;;
    *)
      echo "Refusing to remove unexpected path: ${resolved_expired_backup}" >&2
      exit 1
      ;;
  esac
done

echo "PostgreSQL backup created: ${final_path}"
