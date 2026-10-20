#!/usr/bin/env bash
# Real SSH/rsync push and pull between separate OctoJoom homes on one disposable
# Linux Docker runner. A private sshd listens only on loopback with a temporary
# host key and authorized key. Existing SSH configuration and HOME stay intact.
set -e -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TEST_DIR}/../../src/octojoom"
fail() { printf 'FAIL - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok   - %s\n' "$*"; }
[[ "${OSTYPE}" == linux* ]] || fail 'SSH migration acceptance requires Linux.'
for tool in docker jq ssh ssh-keygen rsync python3 curl timeout sha256sum; do
  command -v "${tool}" >/dev/null || fail "Missing prerequisite: ${tool}"
done
SSHD_BIN="$(type -P sshd || true)"
if [ -z "${SSHD_BIN}" ] && [ -x /usr/sbin/sshd ]; then SSHD_BIN=/usr/sbin/sshd; fi
[ -n "${SSHD_BIN}" ] || fail 'Install openssh-server for this scenario.'
DOCKER_BIN="$(type -P docker)"
SSH_BIN="$(type -P ssh)"
timeout 15s "${DOCKER_BIN}" info >/dev/null
timeout 15s "${DOCKER_BIN}" compose version >/dev/null
if (( EUID != 0 )); then
  if ! command -v sudo >/dev/null || ! sudo -n true; then fail 'Root or passwordless sudo is required.'; fi
fi
privileged() { if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/octojoom-ssh.XXXXXXXX")"
RUN_ID="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n' | tr '0123456789' 'ghijklmnop')"
LOCAL_HOME="${WORK}/local"
REMOTE_HOME="${WORK}/remote"
SOURCE_KEY="origin${RUN_ID}"
PUSH_KEY="remote${RUN_ID}"
PULL_KEY="returned${RUN_ID}"
SOURCE_SITE="origin.${RUN_ID}.invalid"
PUSH_SITE="remote.${RUN_ID}.invalid"
PULL_SITE="returned.${RUN_ID}.invalid"
SSH_USER="$(id -un)"
SSH_PID=''
RESULT="${WORK}/result.json"
ERROR_OUTPUT="${WORK}/errors.log"
KEYS=("${SOURCE_KEY}" "${PUSH_KEY}" "${PULL_KEY}")
SITES=("${SOURCE_SITE}" "${PUSH_SITE}" "${PULL_SITE}")
mkdir -p "${WORK}/bin" "${WORK}/local-tmp" "${WORK}/remote-tmp"

cleanup() {
  local status=$? key service root site compose network pid
  trap - EXIT INT TERM HUP
  set +e
  if (( status != 0 )); then
    [ ! -s "${RESULT}" ] || cat "${RESULT}" >&2
    [ ! -s "${ERROR_OUTPUT}" ] || tail -80 "${ERROR_OUTPUT}" >&2
    [ ! -s "${WORK}/sshd.log" ] || privileged tail -40 "${WORK}/sshd.log" >&2
    for key in "${KEYS[@]}"; do
      for service in joomla mariadb; do
        if timeout 10s "${DOCKER_BIN}" inspect --format '{{.Name}} {{json .State}}' "${service}${key}" >&2 2>/dev/null; then
          timeout 10s "${DOCKER_BIN}" logs --tail 30 "${service}${key}" >&2 2>&1
        fi
      done
    done
  fi
  for root in "${LOCAL_HOME}" "${REMOTE_HOME}"; do
    for site in "${SITES[@]}"; do
      compose="${root}/Docker/joomla/available/${site}/docker-compose.yml"
      [ ! -f "${compose}" ] || timeout 60s "${DOCKER_BIN}" compose --env-file "${compose%/*}/.env" -f "${compose}" down --volumes --remove-orphans >/dev/null 2>&1
    done
  done
  for key in "${KEYS[@]}"; do
    for service in joomla mariadb phpmyadmin; do timeout 15s "${DOCKER_BIN}" rm -fv "${service}${key}" >/dev/null 2>&1; done
    while IFS= read -r network; do
      [ -z "${network}" ] || timeout 15s "${DOCKER_BIN}" network rm "${network}" >/dev/null 2>&1
    done < <("${DOCKER_BIN}" network ls --filter "label=com.docker.compose.project=octojoom${key}" --format '{{.ID}}')
  done
  if [ -s "${WORK}/sshd.pid" ]; then
    pid=$(cat "${WORK}/sshd.pid")
    [[ "${pid}" =~ ^[0-9]+$ ]] && privileged kill "${pid}" >/dev/null 2>&1
  fi
  [ -z "${SSH_PID}" ] || privileged kill "${SSH_PID}" >/dev/null 2>&1
  privileged rm -rf -- "${WORK}"
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

for root in "${LOCAL_HOME}" "${REMOTE_HOME}"; do
  mkdir -p "${root}/.config/octojoom" "${root}/Docker" "${root}/Projects" "${root}/Backups"
  cat >"${root}/.config/octojoom/.env" <<ENV
VDM_REPO_PATH="${root}/Docker"
VDM_PROJECT_PATH="${root}/Projects"
VDM_BACKUP_PATH="${root}/Backups"
VDM_UPDATE_HOST=false
VDM_SECURE=false
ENV
  chmod 600 "${root}/.config/octojoom/.env"
done

# Wrappers supply only this test's SSH config and remote application roots.
# No alias, key or known_hosts entry is installed in the runner's real HOME.
printf '#!/usr/bin/env bash\nexec %q -F %q "$@"\n' "${SSH_BIN}" "${WORK}/ssh_config" >"${WORK}/bin/ssh"
printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "${SCRIPT}" >"${WORK}/bin/octojoom"
cat >"${WORK}/bin/whiptail" <<'SH'
#!/usr/bin/env bash
printf 'Unexpected interactive migration prompt\n' >&2
exit 97
SH
# The generated wrapper expands SSH_ORIGINAL_COMMAND in the authenticated session.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nexport OCTOJOOM_HOME=%q\nexport TMPDIR=%q\nexport PATH=%q\nexec bash --noprofile --norc -c "$SSH_ORIGINAL_COMMAND"\n' \
  "${REMOTE_HOME}" "${WORK}/remote-tmp" "${WORK}/bin:${PATH}" >"${WORK}/remote-command"
chmod 700 "${WORK}/bin/ssh" "${WORK}/bin/octojoom" "${WORK}/bin/whiptail" "${WORK}/remote-command"
PATH="${WORK}/bin:${PATH}"
export PATH
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/host_key"
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/client_key"
cp "${WORK}/client_key.pub" "${WORK}/authorized_keys"
read -r host_type host_key _ <"${WORK}/host_key.pub"
printf 'octojoom-integration %s %s\n' "${host_type}" "${host_key}" >"${WORK}/known_hosts"
SSH_PORT=$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)
cat >"${WORK}/ssh_config" <<CONFIG
Host octojoom-integration
  HostName 127.0.0.1
  Port ${SSH_PORT}
  User ${SSH_USER}
  IdentityFile ${WORK}/client_key
  IdentitiesOnly yes
  HostKeyAlias octojoom-integration
  UserKnownHostsFile ${WORK}/known_hosts
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking yes
  BatchMode yes
  ConnectTimeout 10
CONFIG
cat >"${WORK}/sshd_config" <<CONFIG
Port ${SSH_PORT}
ListenAddress 127.0.0.1
HostKey ${WORK}/host_key
PidFile ${WORK}/sshd.pid
AuthorizedKeysFile ${WORK}/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
StrictModes no
UsePAM yes
AllowUsers ${SSH_USER}
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
LogLevel ERROR
ForceCommand ${WORK}/remote-command
Subsystem sftp internal-sftp
CONFIG
chmod 600 "${WORK}/ssh_config" "${WORK}/sshd_config" "${WORK}/authorized_keys" "${WORK}/known_hosts"
privileged mkdir -p /run/sshd
privileged "${SSHD_BIN}" -t -f "${WORK}/sshd_config"
privileged "${SSHD_BIN}" -D -f "${WORK}/sshd_config" -E "${WORK}/sshd.log" &
SSH_PID=$!
ssh_ready=false
for ((attempt=0; attempt<20; attempt++)); do
  if ssh octojoom-integration true 2>"${ERROR_OUTPUT}"; then ssh_ready=true; break; fi
  sleep 1
done
[ "${ssh_ready}" = true ] || fail 'The isolated SSH server did not accept its test key.'
[ "$(ssh octojoom-integration 'printf "%s" "$OCTOJOOM_HOME"')" = "${REMOTE_HOME}" ] || fail 'SSH command environment did not select the remote OctoJoom home.'
pass 'Authenticated loopback SSH uses isolated keys, verified host identity and remote application roots'

api() {
  local root="$1" group="$2" action="$3" request="$4" status=0
  jq --arg repo "${root}/Docker" --arg projects "${root}/Projects" --arg backups "${root}/Backups" \
    '.+{schema_version:1,repo_path:$repo,project_path:$projects,backup_path:$backups}' <<<"${request}" >"${WORK}/request.json"
  chmod 600 "${WORK}/request.json"
  OCTOJOOM_HOME="${root}" TMPDIR="${WORK}/local-tmp" timeout --signal=TERM --kill-after=20s 600s \
    bash "${SCRIPT}" "${group}" "${action}" --config "${WORK}/request.json" --json --no-interaction \
    >"${RESULT}" 2>"${ERROR_OUTPUT}" || status=$?
  [ "${status}" -eq 0 ] || fail "${group} ${action} failed with status ${status}."
  jq -e -s 'length==1 and .[0].schema_version==1 and .[0].ok==true' "${RESULT}" >/dev/null || fail 'Migration API did not produce one successful JSON result.'
}

sql() {
  local key="$1" statement="$2"
  # shellcheck disable=SC2016
  printf '%s' "${statement}" | timeout 30s "${DOCKER_BIN}" exec -i "joomla${key}" php -r '
    require "/var/www/html/configuration.php"; $c=new JConfig;
    $host=explode(":", $c->host, 2)[0];
    $pdo=new PDO("mysql:host=".$host.";dbname=".$c->db,$c->user,$c->password,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
    $query=$pdo->query(stream_get_contents(STDIN));
    if($query->columnCount())foreach($query->fetchAll(PDO::FETCH_NUM) as $row)echo implode("\t",$row),"\n";
  '
}

assert_site() {
  local key="$1" host="$2" expected="$3" port
  [ "$(sql "${key}" 'SELECT value FROM octojoom_migration_marker WHERE id=1')" = "${expected}" ] || fail 'Migrated database contents are incorrect.'
  [ "$(timeout 15s "${DOCKER_BIN}" exec "joomla${key}" cat /var/www/html/octojoom-migration.txt)" = "${expected}" ] || fail 'Migrated project files are incorrect.'
  # shellcheck disable=SC2016
  timeout 15s "${DOCKER_BIN}" exec "joomla${key}" php -r 'require "/var/www/html/configuration.php"; exit((new JConfig)->host===$argv[1]?0:1);' "mariadb${key}" || fail 'Migration left the source database hostname configured.'
  port=$("${DOCKER_BIN}" inspect --format '{{json .NetworkSettings.Ports}}' "joomla${key}" | jq -er '.["80/tcp"] | select(length==1 and .[0].HostIp=="127.0.0.1") | .[0].HostPort')
  curl -fsS --retry 10 --retry-connrefused --retry-delay 1 --max-time 10 -H "Host: ${host}" "http://127.0.0.1:${port}/" >"${WORK}/homepage"
  grep -qi '<html' "${WORK}/homepage" || fail 'Migrated Joomla did not render its homepage.'
}

api "${LOCAL_HOME}" site create "$(jq -cn --arg site "${SOURCE_SITE}" --arg key "${SOURCE_KEY}" \
  '{site:$site,key:$key,joomla_version:"5.4.9",php_version:"8.3",profile:"local",database_engine:"mariadb",database_version:"11.4.12",admin_email:"integration@example.invalid",install:true,activate:true}')"
sql "${SOURCE_KEY}" 'CREATE TABLE octojoom_migration_marker (id INTEGER PRIMARY KEY, value VARCHAR(80) NOT NULL)'
sql "${SOURCE_KEY}" "INSERT INTO octojoom_migration_marker VALUES (1, 'before-push')"
printf '%s\n' before-push | timeout 15s "${DOCKER_BIN}" exec -i "joomla${SOURCE_KEY}" sh -c 'cat > /var/www/html/octojoom-migration.txt'
original_config=$(timeout 15s "${DOCKER_BIN}" exec "joomla${SOURCE_KEY}" sha256sum /var/www/html/configuration.php)

api "${LOCAL_HOME}" site migrate "$(jq -cn --arg site "${SOURCE_SITE}" --arg target "${PUSH_SITE}" --arg key "${PUSH_KEY}" \
  --arg repo "${REMOTE_HOME}/Docker" --arg projects "${REMOTE_HOME}/Projects" \
  '{site:$site,remote:"octojoom-integration",direction:"push",target_site:$target,target_key:$key,destination_repo:$repo,destination_projects:$projects,profile:"local",tls_mode:"none",yes:true}')"
jq -e --arg site "${PUSH_SITE}" '.data.direction=="push" and .data.source_preserved==true and .data.destination.site==$site' "${RESULT}" >/dev/null || fail 'Push did not report the selected remote destination.'
[ "$(find "${WORK}/remote-tmp" -name project.tar.gz -type f | wc -l | tr -d ' ')" = 1 ] || fail 'Push did not transfer exactly one archive.'
[ "$(find "${LOCAL_HOME}/Backups" -maxdepth 1 -name '*.tar.gz' -type f | wc -l | tr -d ' ')" = 1 ] || fail 'Push created an unexpected number of local archives.'
[ "$(timeout 15s "${DOCKER_BIN}" exec "joomla${SOURCE_KEY}" sha256sum /var/www/html/configuration.php)" = "${original_config}" ] || fail 'Push changed the source Joomla configuration.'
api "${LOCAL_HOME}" site stop "$(jq -cn --arg site "${SOURCE_SITE}" '{site:$site}')"
assert_site "${PUSH_KEY}" "${PUSH_SITE}" before-push
pass 'SSH push transfers one verified archive and restores an independent remote Joomla identity'

sql "${PUSH_KEY}" "UPDATE octojoom_migration_marker SET value='before-pull' WHERE id=1"
printf '%s\n' before-pull | timeout 15s "${DOCKER_BIN}" exec -i "joomla${PUSH_KEY}" sh -c 'cat > /var/www/html/octojoom-migration.txt'
remote_config=$(timeout 15s "${DOCKER_BIN}" exec "joomla${PUSH_KEY}" sha256sum /var/www/html/configuration.php)
api "${LOCAL_HOME}" site migrate "$(jq -cn --arg site "${PUSH_SITE}" --arg target "${PULL_SITE}" --arg key "${PULL_KEY}" \
  --arg repo "${REMOTE_HOME}/Docker" --arg projects "${REMOTE_HOME}/Projects" \
  '{site:$site,remote:"octojoom-integration",direction:"pull",target_site:$target,target_key:$key,source_repo:$repo,source_projects:$projects,profile:"local",tls_mode:"none",yes:true}')"
jq -e --arg site "${PULL_SITE}" '.data.restored==true and .data.site==$site' "${RESULT}" >/dev/null || fail 'Pull did not report the selected local destination.'
[ "$(find "${LOCAL_HOME}/Backups" -maxdepth 1 -name '*.tar.gz' -type f | wc -l | tr -d ' ')" = 2 ] || fail 'Pull did not retain exactly one received archive beside the push archive.'
[ "$(find "${REMOTE_HOME}/Backups" -maxdepth 1 -name '*.tar.gz' -type f | wc -l | tr -d ' ')" = 1 ] || fail 'Pull did not create exactly one remote source archive.'
[ "$(timeout 15s "${DOCKER_BIN}" exec "joomla${PUSH_KEY}" sha256sum /var/www/html/configuration.php)" = "${remote_config}" ] || fail 'Pull changed its remote source configuration.'
api "${REMOTE_HOME}" site stop "$(jq -cn --arg site "${PUSH_SITE}" '{site:$site}')"
assert_site "${PULL_KEY}" "${PULL_SITE}" before-pull
sql "${PULL_KEY}" "UPDATE octojoom_migration_marker SET value='returned-only' WHERE id=1"
api "${REMOTE_HOME}" site start "$(jq -cn --arg site "${PUSH_SITE}" '{site:$site}')"
api "${LOCAL_HOME}" site start "$(jq -cn --arg site "${SOURCE_SITE}" '{site:$site}')"
[ "$(sql "${PUSH_KEY}" 'SELECT value FROM octojoom_migration_marker WHERE id=1')" = before-pull ] || fail 'Pull destination writes reached its remote source database.'
[ "$(sql "${SOURCE_KEY}" 'SELECT value FROM octojoom_migration_marker WHERE id=1')" = before-push ] || fail 'Migration changed the original source database.'
pass 'SSH pull preserves its remote source and produces an independent local Joomla project'
