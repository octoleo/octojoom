#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2317

load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  VDM_CONTAINER_TYPE=joomla
  VDM_TRAEFIK_GATEWAY=destination_gateway
  PACKAGE="${SANDBOX}/package"
  mkdir -p "$PACKAGE/compose" "$PACKAGE/project/joomla" "$PACKAGE/project/db"
  gen_joomla_compose old OLD old source.test true true > "$PACKAGE/compose/docker-compose.yml"
  cat > "$PACKAGE/compose/.env" <<'EOF'
VDM_PROJECT_PATH="/source/projects"
VDM_OLD_DB="same_db"
VDM_OLD_DB_USER="same_user"
VDM_OLD_DB_PASS="literal\$password"
VDM_OLD_DB_ROOT="root-secret"
EOF
  cat > "$PACKAGE/project/joomla/configuration.php" <<'EOF'
<?php
class JConfig {
  public $host = 'mariadbold:3306';
  public $user = 'same_user';
  public $password = 'literal$password';
  public $db = 'same_db';
  public $dbprefix = 'original_';
  public $force_ssl = 2;
  public $live_site = 'https://old.source.test';
  public $cookie_domain = '.source.test';
  public $smtphost = 'mailcatcherold';
}
EOF
  cat > "$PACKAGE/manifest.env" <<'EOF'
VDM_MIGRATION_FORMAT=1
VDM_MIGRATION_CONTAINER="old.source.test"
VDM_MIGRATION_KEY="old"
VDM_MIGRATION_ENV_KEY="OLD"
VDM_MIGRATION_PROJECT_FOLDER="old"
VDM_MIGRATION_SOURCE_PROJECT_PATH="/source/projects"
VDM_MIGRATION_DB_IMAGE="mariadb@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
VDM_MIGRATION_ARCH="amd64"
VDM_MIGRATION_SECURE=true
EOF
}

@test "migration realignment preserves credentials and database identity while changing host and HTTP policy" {
  run realignJoomlaMigration "$PACKAGE" new NEW new.destination.test false '' '' ''
  assert_success
  assert_file_contains "$PACKAGE/compose/.env" 'VDM_NEW_DB="same_db"'
  assert_file_contains "$PACKAGE/compose/.env" 'VDM_NEW_DB_PASS="literal\$password"'
  assert_file_contains "$PACKAGE/compose/.env" "VDM_PROJECT_PATH=\"${VDM_PROJECT_PATH}\""
  assert_file_contains "$PACKAGE/compose/docker-compose.yml" 'name: destination_gateway'
  assert_file_contains "$PACKAGE/compose/docker-compose.yml" 'mariadb@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  assert_file_contains "$PACKAGE/compose/docker-compose.yml" 'traefik.http.routers.joomlanew.entrypoints=web'
  refute_file_contains "$PACKAGE/compose/docker-compose.yml" 'tls.certresolver='
  assert_file_contains "$PACKAGE/project/joomla/configuration.php" "public \$host = 'mariadbnew:3306';"
  assert_file_contains "$PACKAGE/project/joomla/configuration.php" 'public $force_ssl = 0;'
  assert_file_contains "$PACKAGE/project/joomla/configuration.php" "public \$live_site = 'http://new.destination.test';"
  assert_file_contains "$PACKAGE/project/joomla/configuration.php" "public \$cookie_domain = 'new.destination.test';"
  assert_file_contains "$PACKAGE/project/joomla/configuration.php" "public \$dbprefix = 'original_';"
  refute_file_exists "${VDM_REPO_PATH}/joomla/.env"
}

@test "migration can retain source key and switch to the destination HTTPS resolver" {
  run realignJoomlaMigration "$PACKAGE" old OLD old.destination.test true cfresolver '' ''
  assert_success
  assert_file_contains "$PACKAGE/compose/docker-compose.yml" 'traefik.http.routers.joomlaold.tls.certresolver=cfresolver'
  assert_file_contains "$PACKAGE/compose/docker-compose.yml" 'traefik.http.services.joomlaold.loadbalancer.server.port=80'
  assert_file_contains "$PACKAGE/compose/docker-compose.yml" 'traefik.http.services.mailcatcherold.loadbalancer.server.port=1080'
  assert_file_contains "$PACKAGE/project/joomla/configuration.php" 'public $force_ssl = 2;'
  assert_file_contains "$PACKAGE/project/joomla/configuration.php" "public \$live_site = 'https://old.destination.test';"
}

@test "migration rejects custom executable SSL configuration instead of evaluating it" {
  sed 's/public \$force_ssl = 2;/public $force_ssl = system("touch should-not-execute");/' \
    "$PACKAGE/project/joomla/configuration.php" > "$PACKAGE/custom.php"
  mv "$PACKAGE/custom.php" "$PACKAGE/project/joomla/configuration.php"
  run realignJoomlaMigration "$PACKAGE" new NEW new.destination.test false '' '' ''
  assert_failure
  refute_file_exists should-not-execute
}

@test "migration collision guard refuses Docker inspection failure and dangling project links" {
  fail_command docker-ps 42
  run migrationDestinationAvailable new new.destination.test
  assert_status 2
  rm -f "$STUB_DIR/fail/docker-ps"
  ln -s "$SANDBOX/missing" "$VDM_PROJECT_PATH/new"
  run migrationDestinationAvailable new new.destination.test
  assert_status 1
}

@test "migration HTTP activation is blocked by the destination global redirect" {
  docker() {
    case "$*" in
      network*) return 0 ;;
      *State.Running*) printf 'true\n' ;;
      *Config.Cmd*) printf '%s\n' '--entrypoints.web.address=:80' ;;
      *Config.Labels*) printf '%s\n' '{"traefik.http.middlewares.redirect-https.redirectscheme.scheme":"https"}' ;;
      *) return 1 ;;
    esac
  }
  run migrationDestinationReady false ''
  assert_failure
  [[ "$output" == *'redirects HTTP globally'* ]]
}

@test "migration HTTPS activation is blocked when the selected resolver is missing" {
  docker() {
    case "$*" in
      network*) return 0 ;;
      *State.Running*) printf 'true\n' ;;
      *Config.Cmd*) printf '%s\n' '--certificatesresolvers.vdmresolver.acme.httpchallenge=true' ;;
      *Config.Labels*) printf '%s\n' '{"traefik.http.middlewares.joomla-security.headers.stsSeconds":"63072000"}' ;;
      *) return 1 ;;
    esac
  }
  run migrationDestinationReady true cfresolver
  assert_failure
  [[ "$output" == *'resolver is not configured'* ]]
}

@test "migration configuration validation failure keeps passwords out of dialogs" {
  fail_command docker-compose-config 17
  run realignJoomlaMigration "$PACKAGE" new NEW new.destination.test false '' '' ''
  assert_failure
  [[ "$output" != *root-secret* && "$output" != *'literal$password'* ]]
  refute_dialog root-secret
}

@test "migration health checks reject stopped or unhealthy containers" {
  docker() { printf 'unhealthy\n'; }
  run migrationWaitHealthy new 2
  assert_failure
}

@test "migration Compose runs cannot inherit stale project secrets or paths" {
  export VDM_OLD_DB_PASS=wrong-inherited-secret
  export VDM_PROJECT_PATH
  docker() {
    if env | grep -qE '^VDM_(OLD_DB_PASS|PROJECT_PATH)='; then return 88; fi
    return 0
  }
  run migrationRunCompose "$PACKAGE/compose/.env" "$PACKAGE/compose/docker-compose.yml" config -q
  assert_success
  assert_equal "$VDM_OLD_DB_PASS" wrong-inherited-secret
}

@test "migration prepare rolls back both reserved paths after Compose publication fails" {
  extractJoomlaMigration() { cp -a "$PACKAGE/." "$2/"; }
  docker() {
    if [ "$1" = info ]; then printf 'amd64\n'; else command docker "$@"; fi
  }
  cp() {
    case "$*" in *'/compose/.'*) return 1 ;; *) command cp "$@" ;; esac
  }
  runPrivileged() { "$@"; }
  run prepareJoomlaMigration "$SANDBOX/archive.tar.gz" new NEW new.destination.test false '' '' ''
  assert_failure
  [ ! -e "$VDM_PROJECT_PATH/new" ]
  [ ! -e "$VDM_REPO_PATH/joomla/available/new.destination.test" ]
  [ ! -e "$VDM_REPO_PATH/joomla/.clone.lock" ]
}

@test "migration prepare refuses architecture mismatch without publication" {
  extractJoomlaMigration() { cp -a "$PACKAGE/." "$2/"; }
  docker() {
    if [ "$1" = info ]; then printf 'arm64\n'; else command docker "$@"; fi
  }
  run prepareJoomlaMigration "$SANDBOX/archive.tar.gz" new NEW new.destination.test false '' '' ''
  assert_failure
  [ ! -e "$VDM_PROJECT_PATH/new" ]
  [ ! -e "$VDM_REPO_PATH/joomla/available/new.destination.test" ]
  refute_command 'docker compose .*config'
}

@test "migration prepare publishes both parts with private credentials and no enabled target" {
  extractJoomlaMigration() { cp -a "$PACKAGE/." "$2/"; }
  docker() {
    if [ "$1" = info ]; then printf 'amd64\n'; else command docker "$@"; fi
  }
  run prepareJoomlaMigration "$SANDBOX/archive.tar.gz" new NEW new.destination.test false '' '' ''
  assert_success
  assert_file_exists "$VDM_PROJECT_PATH/new/joomla/configuration.php"
  assert_file_exists "$VDM_REPO_PATH/joomla/available/new.destination.test/docker-compose.yml"
  assert_file_contains "$PACKAGE/project/joomla/configuration.php" "public \$host = 'mariadbold:3306';"
  refute_file_exists "$VDM_REPO_PATH/joomla/.env"
  [ ! -e "$VDM_REPO_PATH/joomla/enabled/new.destination.test" ]
  [ ! -e "$VDM_REPO_PATH/joomla/.clone.lock" ]
  if ! is_windows; then assert_equal "$(file_mode "$VDM_REPO_PATH/joomla/available/new.destination.test/.env")" 600; fi
  refute_command 'docker compose .*up'
}

@test "migration cancellation has a distinct result and retains the source archive" {
  tar -czf "$SANDBOX/archive.tar.gz" -C "$PACKAGE" manifest.env compose project
  answers new new.destination.test no no
  run importJoomlaMigration "$SANDBOX/archive.tar.gz"
  assert_status 3
  assert_answers_used
  assert_file_exists "$SANDBOX/archive.tar.gz"
  [ ! -e "$VDM_PROJECT_PATH/new" ]
  [ ! -e "$VDM_REPO_PATH/joomla/available/new.destination.test" ]
}

@test "migration HTTPS preserves development proxy behavior instead of forcing Joomla redirects" {
  sed 's/public \$force_ssl = 2;/public $force_ssl = 0;/' "$PACKAGE/project/joomla/configuration.php" > "$PACKAGE/updated.php"
  mv "$PACKAGE/updated.php" "$PACKAGE/project/joomla/configuration.php"
  run realignJoomlaMigration "$PACKAGE" new NEW new.destination.test true vdmresolver '' ''
  assert_success
  assert_file_contains "$PACKAGE/project/joomla/configuration.php" 'public $force_ssl = 0;'
  assert_file_contains "$PACKAGE/compose/docker-compose.yml" 'traefik.http.routers.joomlanew.entrypoints=websecure'
}

@test "migration application check rejects a same-origin redirect loop" {
  docker() { return 0; }
  curl() { printf '302 https://new.destination.test/'; }
  run migrationVerifyApplication new new.destination.test true
  assert_failure
}

@test "migration application check follows only destination redirects to a successful response" {
  docker() { return 0; }
  curl() {
    case "${*: -1}" in
      https://new.destination.test/) printf '302 https://new.destination.test/en/' ;;
      https://new.destination.test/en/) printf '200 ' ;;
      *) return 1 ;;
    esac
  }
  run migrationVerifyApplication new new.destination.test true
  assert_success
}

prepare_activation_fixture() {
  local destination="$VDM_REPO_PATH/joomla/available/new.destination.test"
  mkdir -p "$destination"
  cp "$PACKAGE/compose/docker-compose.yml" "$destination/docker-compose.yml"
  cp "$PACKAGE/compose/.env" "$destination/.env"
  migrationDestinationReady() { return 0; }
}

@test "migration startup failure shows one visible redacted error without hidden helper dialogs" {
  prepare_activation_fixture
  fail_command docker-compose-up 23
  docker() {
    if [[ "$*" == *' up -d' ]]; then printf 'raw-sensitive-docker-output\n' >&2; fi
    command docker "$@"
  }
  run activateJoomlaMigration new new.destination.test false ''
  assert_failure
  assert_dialog 'The imported site failed activation'
  assert_equal "$(grep -c '^--msgbox' "$STUB_DIR/dialogs.log")" 1
  refute_dialog 'Docker Compose failed for'
  refute_dialog raw-sensitive-docker-output
  [[ "$output" != *raw-sensitive-docker-output* ]]
  [ ! -e "$VDM_REPO_PATH/joomla/enabled/new.destination.test" ]
}

@test "migration preparation cleans its staging and lock after an SSH hangup" {
  extractJoomlaMigration() { kill -HUP "$BASHPID"; return 1; }
  run prepareJoomlaMigration "$SANDBOX/archive.tar.gz" new NEW new.destination.test false '' '' ''
  assert_status 129
  [ ! -e "$VDM_REPO_PATH/joomla/.clone.lock" ]
  [ -z "$(find "$VDM_PROJECT_PATH" -maxdepth 1 -name '.migration.*' -print)" ]
  [ ! -e "$VDM_PROJECT_PATH/new" ]
}

@test "migration activation hangup stops the new target and removes only its enabled marker" {
  prepare_activation_fixture
  migrationWaitHealthy() { kill -HUP "$BASHPID"; return 1; }
  run activateJoomlaMigration new new.destination.test false ''
  assert_status 129
  assert_command 'docker compose .* down'
  [ ! -e "$VDM_REPO_PATH/joomla/enabled/new.destination.test" ]
  assert_file_exists "$VDM_REPO_PATH/joomla/available/new.destination.test/docker-compose.yml"
}

@test "migration activation retains the enabled marker when interruption cleanup cannot stop containers" {
  prepare_activation_fixture
  fail_command docker-compose-down 24
  migrationWaitHealthy() { kill -HUP "$BASHPID"; return 1; }
  run activateJoomlaMigration new new.destination.test false ''
  assert_status 129
  [[ "$output" == *'could not be stopped'* ]]
  [ -e "$VDM_REPO_PATH/joomla/enabled/new.destination.test" ]
  assert_file_exists "$VDM_REPO_PATH/joomla/available/new.destination.test/docker-compose.yml"
}
