#!/usr/bin/env bats
#
# The docker-compose.yml templates (Traefik, Portainer, Joomla, Openssh), the
# docker networks, the running-container and free-port checks, and the
# whiptail, Docker and Docker Compose installers.
#
# Each compose file is validated with the real "docker compose config" when
# docker is installed (${REAL_DOCKER}); elsewhere only its key lines are checked.
# The installers run against the stand-ins: the tests check which commands they
# would run; the sudo stand-in keeps everything outside the sandbox untouched.

# SC2016: the compose files hold ${...} references that must stay literal.
# SC2034: the VDM_* globals are read by the loaded script functions.
# SC2317/SC2329: stand-in functions (open, dpkg, sleep) are called by the script.
# shellcheck disable=SC2016,SC2034,SC2317,SC2329

load ../helpers/common

setup() {
  octojoom_setup
}

# write_compose <name> <command...>: write the command's output as
# ${SANDBOX}/<name>/docker-compose.yml, next to an env file
write_compose() {
  local dir="${SANDBOX}/$1"
  shift
  mkdir -p "${dir}"
  echo "VDM_PROJECT_PATH=\"${VDM_PROJECT_PATH}\"" >"${dir}/.env"
  "$@" >"${dir}/docker-compose.yml"
}

yml_of() { echo "${SANDBOX}/$1/docker-compose.yml"; }

# the real docker compose accepts the file (passes without docker)
compose_valid() {
  [ -n "${REAL_DOCKER}" ] || return 0
  "${REAL_DOCKER}" compose --env-file "${SANDBOX}/$1/.env" --file "$(yml_of "$1")" config -q
}

###############################################################################
# templates

@test "traefikContainer: without Let's Encrypt the resolvers are commented out" {
  VDM_REMOVE_SECURE='#'
  VDM_REMOVE_CLOUDFLARE_SERVICE='#'
  write_compose traefik traefikContainer
  assert_file_contains "$(yml_of traefik)" 'container_name: traefik'
  assert_file_contains "$(yml_of traefik)" '- "443:443"'
  run grep -v '^[[:space:]]*#' "$(yml_of traefik)"
  refute_output_contains 'certificatesresolvers'
  refute_output_contains 'CLOUDFLARE_DNS_API_TOKEN'
  compose_valid traefik
}

@test "traefikContainer: Let's Encrypt with Cloudflare adds the resolvers and the DNS token" {
  VDM_REMOVE_SECURE=''
  VDM_REMOVE_CLOUDFLARE_SERVICE=''
  write_compose traefik traefikContainer
  run grep -v '^[[:space:]]*#' "$(yml_of traefik)"
  assert_output_contains 'certificatesresolvers.vdmresolver'
  assert_output_contains 'CLOUDFLARE_DNS_API_TOKEN'
  compose_valid traefik
}

@test "portainerContainer: routes the sub-domain to portainer" {
  VDM_SUBDOMAIN='port'
  VDM_DOMAIN='vdm.dev'
  VDM_PORT_SECURE_LABELS=''
  VDM_REMOVE_SECURE='#'
  write_compose portainer portainerContainer
  assert_file_contains "$(yml_of portainer)" 'container_name: portainer'
  assert_file_contains "$(yml_of portainer)" 'Host(`port.vdm.dev`)'
  compose_valid portainer
}

@test "portainerContainer: Let's Encrypt adds the secure labels" {
  VDM_SUBDOMAIN='port'
  VDM_DOMAIN='vdm.dev'
  VDM_REMOVE_SECURE=''
  VDM_PORT_SECURE_LABELS=$(getYMLine3 '- "traefik.http.routers.portainer.entrypoints=websecure"')
  VDM_PORT_SECURE_LABELS+=$(getYMLine3 '- "traefik.http.routers.portainer.tls.certresolver=vdmresolver"')
  write_compose portainer portainerContainer
  assert_file_contains "$(yml_of portainer)" 'portainer.entrypoints=websecure'
  assert_file_contains "$(yml_of portainer)" 'portainer.tls.certresolver=vdmresolver'
  compose_valid portainer
}

@test "joomlaContainer: has the database, Joomla and phpMyAdmin services" {
  write_compose joomla gen_joomla_compose jtest JTEST jtest vdm.dev
  assert_file_contains "$(yml_of joomla)" 'container_name: mariadbjtest'
  assert_file_contains "$(yml_of joomla)" 'container_name: joomlajtest'
  assert_file_contains "$(yml_of joomla)" 'container_name: phpmyadminjtest'
  assert_file_contains "$(yml_of joomla)" 'Host(`jtest.vdm.dev`)'
  compose_valid joomla
}

@test "joomlaContainer: Let's Encrypt and mailcatcher still give a valid file" {
  write_compose joomla gen_joomla_compose jtest JTEST jtest vdm.dev true true
  assert_file_contains "$(yml_of joomla)" 'joomlajtest.tls.certresolver=vdmresolver'
  assert_file_contains "$(yml_of joomla)" 'container_name: mailcatcherjtest'
  assert_file_contains "$(yml_of joomla)" 'JOOMLA_SMTP_HOST=mailcatcherjtest:1025'
  compose_valid joomla
}

openssh_globals() {
  VDM_KEY='ssh1'
  VDM_DOMAIN='vdm.dev'
  VDM_USER_NAME='alice'
  VDM_PUID=33
  VDM_PGID=33
  VDM_PORT=2239
  VDM_VOLUMES_MOUNT=$(getYMLine3 '- ${VDM_SSH1_PUBLIC_KEY_DIR}:/config/ssh_public_keys')
}

@test "opensshContainer: the user, port and key folder" {
  openssh_globals
  write_compose openssh opensshContainer
  echo "VDM_SSH1_PUBLIC_KEY_DIR=\"${SANDBOX}/keys\"" >>"${SANDBOX}/openssh/.env"
  assert_file_contains "$(yml_of openssh)" 'container_name: openssh-server-ssh1'
  assert_file_contains "$(yml_of openssh)" '- USER_NAME=alice'
  assert_file_contains "$(yml_of openssh)" '- 2239:2222'
  assert_file_contains "$(yml_of openssh)" 'name: openssh_gateway'
  compose_valid openssh
}

@test "opensshContainer: time zone, sudo access and gateway can be set" {
  openssh_globals
  VDM_TZ='Europe/Berlin'
  VDM_SUDO_ACCESS=true
  VDM_OPENSSH_GATEWAY='ssh_net'
  write_compose openssh opensshContainer
  echo "VDM_SSH1_PUBLIC_KEY_DIR=\"${SANDBOX}/keys\"" >>"${SANDBOX}/openssh/.env"
  assert_file_contains "$(yml_of openssh)" '- TZ=Europe/Berlin'
  assert_file_contains "$(yml_of openssh)" '- SUDO_ACCESS=true'
  assert_file_contains "$(yml_of openssh)" 'name: ssh_net'
  compose_valid openssh
}

###############################################################################
# setNetworks

@test "setNetworks: creates the traefik and openssh networks" {
  run setNetworks
  assert_success
  assert_command '^docker network create .*traefik_webgateway$'
  assert_command '^docker network create .*openssh_gateway$'
  assert_file_contains "${STUB_DIR}/docker/networks" 'traefik_webgateway'
  assert_file_contains "${STUB_DIR}/docker/networks" 'openssh_gateway'
}

@test "setNetworks: existing networks are left alone" {
  printf '%s\n' traefik_webgateway openssh_gateway >"${STUB_DIR}/docker/networks"
  run setNetworks
  assert_success
  refute_command '^docker network create'
}

@test "setNetworks: fails when docker is not reachable" {
  fail_command docker-info
  run setNetworks
  assert_failure
  refute_command '^docker network'
}

###############################################################################
# isContainerRunning

@test "isContainerRunning: only an exactly named running container counts" {
  running_containers traefik2 mariadbjtest
  run isContainerRunning mariadbjtest
  assert_success
  run isContainerRunning traefik
  assert_failure
}

@test "isContainerRunning: daemon query failure is distinct from a stopped container" {
  running_containers traefik
  fail_command docker-ps
  run isContainerRunning traefik
  assert_status 2
}

###############################################################################
# ensurePortsFree

# lsof (through sudo) reports nginx on port 80 until "sudo systemctl stop" runs
ports_used_by_nginx() {
  echo 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME' >"${STUB_DIR}/lsof-out"
  echo 'nginx 1234 root 6u IPv4 12345 0t0 TCP *:80 (LISTEN)' >>"${STUB_DIR}/lsof-out"
  hook_command sudo <<'EOF'
case "$1" in
lsof) [ -f "${STUB_DIR}/lsof-out" ] && cat "${STUB_DIR}/lsof-out" ;;
systemctl) [ "$2" = stop ] && rm -f "${STUB_DIR}/lsof-out" ;;
esac
exit 0
EOF
}

@test "ensurePortsFree: free ports pass without a question" {
  OS_NUMBER=1
  run ensurePortsFree
  assert_success
  assert_command '^sudo lsof '
  refute_command '^sudo systemctl'
}

@test "ensurePortsFree: a Linux web service is stopped when the user agrees" {
  OS_NUMBER=1
  ports_used_by_nginx
  sleep() { :; }
  answers yes
  run ensurePortsFree
  assert_success
  assert_command '^sudo systemctl stop nginx$'
  assert_command '^sudo systemctl disable nginx$'
}

@test "ensurePortsFree: declining leaves the service running and fails" {
  OS_NUMBER=1
  ports_used_by_nginx
  answers no
  run ensurePortsFree
  assert_failure
  refute_command '^sudo systemctl'
  assert_file_exists "${STUB_DIR}/lsof-out"
}

###############################################################################
# installers (the sudo stand-in skips every system change)

@test "install_whiptail_linux: installs whiptail with apt-get through sudo" {
  run install_whiptail_linux
  assert_success
  assert_command '^sudo apt-get install whiptail -y$'
  refute_command '^apt-get'
}

@test "install_whiptail_macos: installs newt with Homebrew" {
  run install_whiptail_macos
  assert_success
  assert_command '^brew install newt$'
}

@test "install_whiptail_windows: installs newt with Chocolatey" {
  run install_whiptail_windows
  assert_success
  assert_command '^choco install newt --yes$'
}

@test "install_docker_linux: Debian adds the Docker repository and installs Docker" {
  printf '%s\n' 'ID=debian' 'VERSION_CODENAME=bookworm' >"${SANDBOX}/os-release"
  eval "$(declare -f install_docker_linux | sed "s|/etc/os-release|${SANDBOX}/os-release|g")"
  dpkg() { echo amd64; }
  run install_docker_linux
  assert_success
  assert_file_contains "${STUB_DIR}/sudo-tee.log" 'https://download.docker.com/linux/debian bookworm stable'
  assert_command '^sudo apt-get install -y docker-ce '
  assert_command '^sudo usermod -aG docker '
  assert_command '^sudo systemctl start docker\.service$'
  # nothing really ran outside the sandbox
  refute_command '^(apt-get|groupadd|usermod|systemctl|gpg) '
}

@test "installer GPG stand-in: consumes the complete download under pipefail" {
  printf '%131072s' key >"${STUB_DIR}/curl-body"
  run bash -o pipefail -c 'curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --batch --yes --dearmor -o "$SANDBOX/key.gpg"'
  assert_success
  assert_command '^sudo gpg --batch --yes --dearmor '
  refute_command '^gpg '
  refute_file_exists "${SANDBOX}/key.gpg"
}

@test "installer GPG stand-in: a failing command hook is not converted into success" {
  hook_command sudo <<'EOF'
[ "$1" != gpg ] || exit 42
exit 0
EOF
  run bash -o pipefail -c 'curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --batch --yes --dearmor -o "$SANDBOX/key.gpg"'
  assert_status 42
  refute_file_exists "${SANDBOX}/key.gpg"
}

@test "install_docker_macos: installs Docker Desktop with Homebrew and starts it" {
  eval "$(declare -f install_docker_macos | sed "s|/Applications/Docker.app|${SANDBOX}/Docker.app|g")"
  open() { echo "open $*" >>"${STUB_DIR}/commands.log"; }
  run install_docker_macos
  assert_success
  assert_command '^brew install --cask docker$'
  assert_command '^open .*/Docker\.app$'
  refute_command '^(sudo|curl) '
}

@test "install_docker_compose_linux: installs the compose plugin with apt-get" {
  run install_docker_compose_linux
  assert_success
  assert_command '^sudo apt-get install -y docker-compose-plugin$'
  refute_command '^apt-get'
}

@test "install_docker_compose_macos: nothing to download when compose is available" {
  run install_docker_compose_macos
  assert_success
  refute_command '^curl'
}

@test "install_whiptail_linux: apt refresh failure prevents installation" {
  hook_command sudo <<'EOF'
[ "$1 $2" != 'apt-get update' ] || exit 42
exit 0
EOF
  run install_whiptail_linux
  assert_failure
  refute_command '^sudo apt-get install'
}

whiptail_manager() {
  TEST_PACKAGE_MANAGER="$1"
  command() {
    if [ "${1:-}" = -v ]; then
      case "${2:-}" in
        apt-get|dnf|yum|pacman|zypper)
          [ "$2" = "$TEST_PACKAGE_MANAGER" ] || return 1
          ;;
      esac
    fi
    builtin command "$@"
  }
}

@test "install_whiptail_linux: selects the correct package on RPM, Arch and SUSE systems" {
  local manager expected
  for manager in dnf yum pacman zypper; do
    whiptail_manager "$manager"
    : >"${STUB_DIR}/commands.log"
    run install_whiptail_linux
    assert_success
    case "$manager" in
      dnf|yum) expected="^sudo $manager install -y newt$" ;;
      pacman) expected='^sudo pacman -S --needed --noconfirm libnewt$' ;;
      zypper) expected='^sudo zypper install -y newt$' ;;
    esac
    assert_command "$expected"
    refute_command '^sudo apt-get '
  done
}

@test "install_whiptail_linux: an unsupported package manager requires manual installation" {
  whiptail_manager none
  run install_whiptail_linux
  assert_failure
  assert_output_contains 'install whiptail manually'
  refute_command '^sudo '
}

@test "install_whiptail_macos: Homebrew failure is returned" {
  fail_command brew 42
  run install_whiptail_macos
  assert_failure
}

@test "install_whiptail_windows: Chocolatey failure is returned" {
  fail_command choco 42
  run install_whiptail_windows
  assert_failure
}

linux_release() {
  printf '%s\n' "$@" >"${SANDBOX}/os-release"
  eval "$(declare -f install_docker_linux | sed "s|/etc/os-release|${SANDBOX}/os-release|g")"
  dpkg() { echo amd64; }
}

@test "install_docker_linux: Mint uses Ubuntu's key and parent codename" {
  linux_release ID=linuxmint 'ID_LIKE="ubuntu debian"' VERSION_CODENAME=wilma UBUNTU_CODENAME=noble
  run install_docker_linux
  assert_success
  assert_command '^curl -fsSL https://download.docker.com/linux/ubuntu/gpg$'
  assert_file_contains "${STUB_DIR}/sudo-tee.log" 'https://download.docker.com/linux/ubuntu noble stable'
  refute_file_contains "${STUB_DIR}/sudo-tee.log" wilma
}

@test "install_docker_linux: Fedora uses Fedora's repository with DNF5" {
  linux_release ID=fedora ID_LIKE=rhel VERSION_CODENAME=''
  run install_docker_linux
  assert_success
  assert_command '^sudo dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo$'
  refute_command 'https://download.docker.com/linux/centos/'
  refute_command '^sudo (dnf|yum) remove -y (podman|containerd|runc)$'
}

@test "install_docker_linux: invalid parent codename aborts before removing packages" {
  linux_release ID=kali ID_LIKE=debian VERSION_CODENAME=kali-rolling
  run install_docker_linux
  assert_failure
  refute_command '^sudo '
}

@test "install_docker_linux: SUSE requires manual Docker setup before any package changes" {
  linux_release ID=opensuse-leap ID_LIKE=suse VERSION_CODENAME=''
  run install_docker_linux
  assert_failure
  refute_command '^sudo '
  assert_output_contains 'install Docker manually'
}

@test "install_docker_linux: failed GPG download stops repository setup" {
  linux_release ID=debian VERSION_CODENAME=bookworm
  fail_command curl 22
  run install_docker_linux
  assert_failure
  refute_command '^sudo tee '
  refute_command '^sudo usermod '
  refute_output_contains 'Docker is installed.'
}

@test "install_docker_linux: package installation failure stops group and service changes" {
  linux_release ID=debian VERSION_CODENAME=bookworm
  hook_command sudo <<'EOF'
case "$*" in 'apt-get install -y docker-ce '*) exit 42 ;; esac
[ "$1" != tee ] || cat >>"${STUB_DIR}/sudo-tee.log"
exit 0
EOF
  run install_docker_linux
  assert_failure
  refute_command '^sudo usermod '
  refute_command '^sudo systemctl '
  refute_output_contains 'Docker is installed.'
}

@test "install_docker_linux: service startup failure does not report successful installation" {
  linux_release ID=debian VERSION_CODENAME=bookworm
  hook_command sudo <<'EOF'
[ "$*" != 'systemctl start docker.service' ] || exit 42
[ "$1" != tee ] || cat >>"${STUB_DIR}/sudo-tee.log"
exit 0
EOF
  run install_docker_linux
  assert_failure
  refute_command '^sudo systemctl start containerd.service$'
  refute_output_contains 'Docker is installed.'
}

@test "install_docker_macos: failed cask install never launches Docker Desktop" {
  fail_command brew 42
  open() { echo "open $*" >>"${STUB_DIR}/commands.log"; }
  run install_docker_macos
  assert_failure
  refute_command '^open '
}

@test "install_docker_macos: successful desktop setup does not request a Linux group login" {
  eval "$(declare -f install_docker_macos | sed "s|/Applications/Docker.app|${SANDBOX}/Docker.app|g")"
  open() { :; }
  install_docker_macos
  [ "$DOCKER_INSTALLED_THIS_SESSION" = false ]
}

@test "install_docker_compose_linux: package failure cannot be hidden by a working plugin" {
  hook_command sudo <<'EOF'
[ "$1 $2" != 'apt-get install' ] || exit 42
exit 0
EOF
  run install_docker_compose_linux
  assert_failure
  refute_command '^docker compose version$'
  refute_output_contains 'plugin is installed.'
}

@test "install_docker_compose_macos: API failure leaves the installed plugin untouched" {
  eval "$(declare -f install_docker_compose_macos | awk -v target="$OCTOJOOM_HOME" '{ gsub(/\$HOME/, target); print }')"
  mkdir -p "$OCTOJOOM_HOME/.docker/cli-plugins"
  printf 'existing plugin\n' >"$OCTOJOOM_HOME/.docker/cli-plugins/docker-compose"
  fail_command docker-compose-version
  fail_command curl 22
  run install_docker_compose_macos
  assert_failure
  assert_file_contains "$OCTOJOOM_HOME/.docker/cli-plugins/docker-compose" 'existing plugin'
  refute_output_contains 'plugin v'
}

@test "install_docker_compose_macos: malformed release metadata is rejected" {
  fail_command docker-compose-version
  printf '{"message":"API rate limit exceeded"}\n' >"${STUB_DIR}/curl-body"
  run install_docker_compose_macos
  assert_failure
  assert_output_contains 'Could not determine'
  refute_command 'github.com/docker/compose/releases/download/'
}

compose_download_fixture() {
  eval "$(declare -f install_docker_compose_macos | awk -v target="$OCTOJOOM_HOME" '{ gsub(/\$HOME/, target); print }')"
  mkdir -p "$OCTOJOOM_HOME/.docker/cli-plugins"
  printf 'existing plugin\n' >"$OCTOJOOM_HOME/.docker/cli-plugins/docker-compose"
  fail_command docker-compose-version
  hook_command curl <<'EOF'
case "$*" in
*api.github.com*) printf '{"tag_name":"v2.40.0"}\n' ;;
*)
  while [ $# -gt 0 ]; do
    if [ "$1" = -o ]; then
      cp "${STUB_DIR}/compose-binary" "$2"
      exit $?
    fi
    shift
  done
  exit 1
  ;;
esac
EOF
}

@test "install_docker_compose_macos: a downloaded binary is checked before replacement" {
  compose_download_fixture
  printf '#!/usr/bin/env bash\nexit 42\n' >"${STUB_DIR}/compose-binary"
  run install_docker_compose_macos
  assert_failure
  assert_file_contains "$OCTOJOOM_HOME/.docker/cli-plugins/docker-compose" 'existing plugin'
  [ -z "$(find "$OCTOJOOM_HOME/.docker/cli-plugins" -name '.docker-compose.*' -print)" ]
}

@test "install_docker_compose_macos: a validated downloaded plugin is installed executable" {
  compose_download_fixture
  printf '#!/usr/bin/env bash\necho Docker Compose version v2.40.0\n' >"${STUB_DIR}/compose-binary"
  run install_docker_compose_macos
  assert_success
  assert_file_contains "$OCTOJOOM_HOME/.docker/cli-plugins/docker-compose" 'v2.40.0'
  [ -x "$OCTOJOOM_HOME/.docker/cli-plugins/docker-compose" ]
  [ -z "$(find "$OCTOJOOM_HOME/.docker/cli-plugins" -name '.docker-compose.*' -print)" ]
}

@test "install_docker_windows: directs users to Docker Desktop without modifying the host" {
  run install_docker_windows
  assert_success
  assert_output_contains 'Docker Desktop is required for Windows environments.'
  refute_command '^sudo '
}

@test "install_docker_compose_windows: explains the Compose plugin bundled with Docker Desktop" {
  run install_docker_compose_windows
  assert_success
  assert_output_contains 'includes Docker Compose V2 by default.'
  refute_command '^sudo '
}

@test "octojoomQuietly: displays version, purpose, and author" {
  run octojoomQuietly
  assert_success
  assert_dialog "Octojoom v${_VERSION}"
  assert_dialog 'deploy docker containers of Joomla and Openssh'
  assert_dialog 'Llewellyn van der Merwe'
}

# Substitute only the install paths in the real function and allow install to
# operate on those test files; every other sudo command still uses the stand-in.
sandbox_update() {
  mkdir -p "${SANDBOX}/bin"
  eval "$(declare -f runUpdate | awk -v target="${SANDBOX}" '{
    gsub(/\/usr\/local\/bin/, target "/bin")
    gsub(/\$\{TMPDIR:-\/tmp\}/, target)
    print
  }')"
  sudo() {
    if [ "${1:-}" = install ]; then
      echo "sudo $*" >>"${STUB_DIR}/commands.log"
      "$@"
    else
      command sudo "$@"
    fi
  }
  isExpert() { return 1; }
  quitProgram() { echo quit >>"${STUB_DIR}/commands.log"; }
  printf '#!/usr/bin/env bash\necho old\n' >"${SANDBOX}/bin/octojoom"
}

@test "runUpdate: validates and atomically installs a complete executable" {
  sandbox_update
  answers yes
  printf '#!/usr/bin/env bash\necho updated\n' >"${STUB_DIR}/curl-body"
  run runUpdate
  assert_success
  assert_file_contains "${SANDBOX}/bin/octojoom" 'echo updated'
  [ -x "${SANDBOX}/bin/octojoom" ]
  assert_command '^quit$'
  refute_command '^sudo curl '
  [ -z "$(find "${SANDBOX}/bin" -name '.octojoom-update.*' -print)" ]
}

@test "runUpdate: a failed download preserves the installed executable and returns failure" {
  sandbox_update
  answers yes
  fail_command curl 22
  run runUpdate
  assert_failure
  assert_file_contains "${SANDBOX}/bin/octojoom" 'echo old'
  refute_command '^sudo (mv|install) '
  refute_command '^quit$'
}

@test "runUpdate: syntax errors cannot replace the installed executable" {
  sandbox_update
  answers yes
  printf '#!/usr/bin/env bash\nif\n' >"${STUB_DIR}/curl-body"
  run runUpdate
  assert_failure
  assert_file_contains "${SANDBOX}/bin/octojoom" 'echo old'
  refute_command '^sudo (mv|install) '
  refute_command '^quit$'
}

@test "runUpdate: failed privileged installation preserves the original executable" {
  sandbox_update
  answers yes
  printf '#!/usr/bin/env bash\necho updated\n' >"${STUB_DIR}/curl-body"
  hook_command sudo <<'EOF'
[ "$1" != mv ] || exit 42
exec "$@"
EOF
  run runUpdate
  assert_failure
  assert_file_contains "${SANDBOX}/bin/octojoom" 'echo old'
  refute_command '^quit$'
  [ -z "$(find "${SANDBOX}/bin" -name '.octojoom-update.*' -print)" ]
}

@test "runUninstall: failed container shutdown preserves its configuration" {
  make_joomla_container keep KEEP keep
  link_enabled joomla keep.vdm.dev
  answers yes yes
  downContainers() { return 42; }
  run runUninstall
  assert_failure
  assert_file_exists "${VDM_REPO_PATH}/joomla/available/keep.vdm.dev/docker-compose.yml"
  refute_command '^sudo rm '
}

sandbox_uninstall() {
  mkdir -p "${SANDBOX}/bin"
  eval "$(declare -f runUninstall | sed "s|/usr/local/bin|${SANDBOX}/bin|g")"
  quitProgram() { echo quit >>"${STUB_DIR}/commands.log"; exit 0; }
  printf '#!/usr/bin/env bash\necho old\n' >"${SANDBOX}/bin/octojoom"
}

@test "runUninstall: cancellation leaves the application and its configuration installed" {
  sandbox_uninstall
  answers no
  run runUninstall
  assert_success
  assert_file_exists "${SANDBOX}/bin/octojoom"
  assert_file_exists "$VDM_SRC_PATH"
  refute_command '^sudo rm '
  refute_command '^quit$'
}

@test "runUninstall: script-only removal keeps all Docker paths and persistent data" {
  sandbox_uninstall
  answers yes no yes
  run runUninstall
  assert_success
  refute_file_exists "${SANDBOX}/bin/octojoom"
  assert_file_exists "$VDM_REPO_PATH"
  assert_file_exists "$VDM_SRC_PATH"
  assert_file_exists "$VDM_PROJECT_PATH"
  assert_command '^quit$'
}

@test "runUninstall: complete removal stops containers and respects declining volume deletion" {
  sandbox_uninstall
  make_joomla_container keep KEEP keep
  link_enabled joomla keep.vdm.dev
  answers yes yes yes no
  run runUninstall
  assert_success
  refute_file_exists "${SANDBOX}/bin/octojoom"
  refute_file_exists "$VDM_REPO_PATH"
  refute_file_exists "$VDM_SRC_PATH"
  assert_file_exists "$VDM_PROJECT_PATH/keep/joomla"
  assert_command '^docker compose .* down$'
  assert_command '^quit$'
}

@test "runUninstall: incomplete single-container configuration can be removed without Docker" {
  sandbox_uninstall
  mkdir -p "$VDM_REPO_PATH/portainer" "$VDM_REPO_PATH/traefik"
  answers yes yes no
  run runUninstall
  assert_success
  refute_file_exists "$VDM_REPO_PATH"
  refute_command '^docker compose '
}

@test "runUninstall: unsafe repository paths fail before removing any configuration" {
  VDM_REPO_PATH="$VDM_HOME_PATH"
  answers yes yes
  run runUninstall
  assert_failure
  assert_file_exists "$VDM_HOME_PATH"
  refute_command '^sudo rm '
}

@test "removeOctojoomDirectory: a selected application directory can be removed" {
  mkdir -p "${SANDBOX}/owned directory"
  run removeOctojoomDirectory "${SANDBOX}/owned directory"
  assert_success
  refute_file_exists "${SANDBOX}/owned directory"
}

@test "validateOctojoomRemovalPath: rejects home, root and relative paths" {
  local directory
  for directory in / "$VDM_HOME_PATH" .; do
    run validateOctojoomRemovalPath "$directory"
    assert_failure
  done
  refute_command '^sudo rm '
}

@test "validateOctojoomRemovalPath: resolves links before allowing directory deletion" {
  skip_on_windows 'Git Bash can copy directories instead of creating native symlinks'
  ln -s "$VDM_HOME_PATH" "${SANDBOX}/home-link"
  run validateOctojoomRemovalPath "${SANDBOX}/home-link"
  assert_failure
  refute_command '^sudo rm '
}

@test "validateOctojoomRemovalPath: protects the actual home behind a configured symlink" {
  skip_on_windows 'Git Bash can copy directories instead of creating native symlinks'
  mkdir -p "${SANDBOX}/protected-home"
  ln -s "${SANDBOX}/protected-home" "${SANDBOX}/linked-home"
  VDM_HOME_PATH="${SANDBOX}/linked-home"
  run validateOctojoomRemovalPath "${SANDBOX}/protected-home"
  assert_failure
  refute_command '^sudo rm '
}
