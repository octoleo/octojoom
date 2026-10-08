#!/usr/bin/env bats

# Globals and injected helpers are consumed by the loaded application; dotenv
# fixtures deliberately contain literal shell expressions. Lookups assign by name.
# shellcheck disable=SC2034,SC2016,SC2154,SC2317

load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  TMPDIR="$SANDBOX"
  export TMPDIR
  VDM_CONTAINER_TYPE=joomla
  PACKAGE_SOURCE="$VDM_REPO_PATH/joomla/available/source.example.org"
  mkdir -p "$PACKAGE_SOURCE" "$VDM_PROJECT_PATH/source/db" "$VDM_PROJECT_PATH/source/joomla"
  cat > "$PACKAGE_SOURCE/docker-compose.yml" <<'EOF'
services:
  mariadbsource:
    image: mariadb:latest
    container_name: mariadbsource
    environment:
      - MARIADB_DATABASE=${VDM_SOURCE_DB}
      - MARIADB_USER=${VDM_SOURCE_DB_USER}
      - MARIADB_PASSWORD=${VDM_SOURCE_DB_PASS}
      - MARIADB_ROOT_PASSWORD=${VDM_SOURCE_DB_ROOT}
    volumes:
      - "${VDM_PROJECT_PATH}/source/db:/var/lib/mysql"
  joomlasource:
    image: joomla:5
    container_name: joomlasource
    volumes:
      - "${VDM_PROJECT_PATH}/source/joomla:/var/www/html"
      - "./php.ini:/usr/local/etc/php/conf.d/site.ini:ro"
EOF
  printf 'memory_limit=256M\n' > "$PACKAGE_SOURCE/php.ini"
  printf 'do not export\n' > "$PACKAGE_SOURCE/unrelated.secret"
  {
    formatEnvAssignment "VDM_PROJECT_PATH=\"$VDM_PROJECT_PATH\""
    formatEnvAssignment 'VDM_SOURCE_DB=database'
    formatEnvAssignment 'VDM_SOURCE_DB_USER=databaseuser'
    formatEnvAssignment 'VDM_SOURCE_DB_PASS="secret $literal \\ value"'
    formatEnvAssignment 'VDM_SOURCE_DB_ROOT=rootpassword'
    formatEnvAssignment 'VDM_UNRELATED_DB_PASS=unrelatedpassword'
  } > "$VDM_REPO_PATH/joomla/.env"
  cat > "$VDM_PROJECT_PATH/source/joomla/configuration.php" <<'EOF'
<?php
class JConfig {
  public $host = 'mariadbsource';
  public $db = 'database';
  public $user = 'databaseuser';
  public $password = 'secret';
}
EOF
  printf 'cold database bytes\n' > "$VDM_PROJECT_PATH/source/db/ibdata1"
  chmod 644 "$VDM_PROJECT_PATH/source/joomla/configuration.php"
  hook_command docker <<'EOF'
case "$1" in
info) printf 'x86_64\n' ;;
image)
  case "$*" in *'{{.Architecture}}'*) printf 'amd64\n' ;; *) printf 'mariadb@sha256:%064d\n' 1 ;; esac ;;
ps) printf 'mariadbsource\njoomlasource\n' ;;
inspect)
  case "$*" in
    *'{{.Image}}'*) printf 'sha256:%064d\n' 2 ;;
    *'.Mounts'*)
      if [ "${*: -1}" = joomlasource ]; then
        printf 'bind\t%s/source/joomla\t/var/www/html\n' "$VDM_PROJECT_PATH"
      else
        printf 'bind\t%s/source/db\t/var/lib/mysql\n' "$VDM_PROJECT_PATH"
      fi ;;
    *'{{.Id}} {{.State.Running}}'*)
      case "${*: -1}" in mariadbsource) number=3 ;; joomlasource) number=4 ;; *) exit 1 ;; esac
      printf '%064d true\n' "$number" ;;
    *'{{.State.Running}}'*)
      if [ -f "$STUB_DIR/source-stopped" ]; then printf 'false\n'; else printf 'true\n'; fi ;;
    *) exit 1 ;;
  esac ;;
stop) touch "$STUB_DIR/source-stopped" ;;
start) rm -f "$STUB_DIR/source-stopped" ;;
*) exit 1 ;;
esac
EOF
}

@test "migration package: exports scoped secrets, companion files and cold data; restarts source" {
  run exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  assert_success
  assert_equal "$(file_mode "$SANDBOX/project.tar.gz")" 600
  refute_file_exists "$STUB_DIR/source-stopped"
  refute_file_exists "$VDM_REPO_PATH/joomla/.clone.lock"
  mkdir -m 700 "$SANDBOX/unpacked"
  run extractJoomlaMigration "$SANDBOX/project.tar.gz" "$SANDBOX/unpacked"
  assert_success
  assert_file_contains "$SANDBOX/unpacked/project/db/ibdata1" 'cold database bytes'
  assert_file_contains "$SANDBOX/unpacked/compose/php.ini" 'memory_limit=256M'
  refute_file_exists "$SANDBOX/unpacked/compose/unrelated.secret"
  run grep -F unrelatedpassword "$SANDBOX/unpacked/compose/.env"
  assert_failure
  migrationReadEnvValue "$SANDBOX/unpacked/compose/.env" VDM_SOURCE_DB_PASS actual
  migrationReadEnvValue "$VDM_REPO_PATH/joomla/.env" VDM_SOURCE_DB_PASS expected
  assert_equal "$actual" "$expected"
  assert_equal "$(file_mode "$SANDBOX/unpacked/project/joomla/configuration.php")" 644
  assert_command '^docker stop '
  assert_command '^docker start '
}

@test "migration package: missing required env fails before stopping services" {
  sed '/VDM_SOURCE_DB_PASS=/d' "$VDM_REPO_PATH/joomla/.env" > "$SANDBOX/env.next"
  mv "$SANDBOX/env.next" "$VDM_REPO_PATH/joomla/.env"
  run exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  assert_failure
  refute_command '^docker stop '
  refute_file_exists "$SANDBOX/project.tar.gz"
}

@test "migration package: refuses external database before stopping services" {
  sed 's/mariadbsource/remote.example.org/' "$VDM_PROJECT_PATH/source/joomla/configuration.php" > "$SANDBOX/config.next"
  mv "$SANDBOX/config.next" "$VDM_PROJECT_PATH/source/joomla/configuration.php"
  run exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  assert_failure
  refute_command '^docker stop '
}

@test "migration package: refuses symlink project content before stopping services" {
  ln -s /etc/passwd "$VDM_PROJECT_PATH/source/joomla/unsafe"
  run exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  assert_failure
  refute_command '^docker stop '
}

@test "migration package: restarts services and removes staging after copy failure" {
  runPrivileged() {
    if [ "$1" = cp ] && [[ "$*" == *'/source/.'* ]]; then return 1; fi
    command "$@"
  }
  run exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  assert_failure
  refute_file_exists "$STUB_DIR/source-stopped"
  refute_file_exists "$VDM_REPO_PATH/joomla/.clone.lock"
  refute_file_exists "$SANDBOX/project.tar.gz"
  assert_command '^docker start '
}

@test "migration package: shares the clone lock" {
  mkdir "$VDM_REPO_PATH/joomla/.clone.lock"
  run exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  assert_failure
  refute_command '^docker stop '
  assert_file_exists "$VDM_REPO_PATH/joomla/.clone.lock"
}

@test "migration package: source restart and lock cleanup survive a termination signal" {
  runPrivileged() {
    if [ "$1" = cp ] && [[ "$*" == *'/source/.'* ]]; then
      kill -TERM "$BASHPID"
      return 143
    fi
    command "$@"
  }
  run exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  assert_failure
  refute_file_exists "$STUB_DIR/source-stopped"
  refute_file_exists "$VDM_REPO_PATH/joomla/.clone.lock"
  refute_file_exists "$SANDBOX/project.tar.gz"
  assert_command '^docker start '
}

@test "migration package: stop failure restarts the original source and fails export" {
  docker() {
    command docker "$@" || return $?
    [ "$1" != stop ]
  }
  run exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  assert_failure
  refute_file_exists "$STUB_DIR/source-stopped"
  refute_file_exists "$SANDBOX/project.tar.gz"
  refute_file_exists "$VDM_REPO_PATH/joomla/.clone.lock"
}

@test "migration package: source restart failure cannot report a successful package" {
  docker() {
    [ "$1" != start ] || return 1
    command docker "$@"
  }
  run exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  assert_failure
  assert_dialog 'could not be restarted'
  refute_file_exists "$SANDBOX/project.tar.gz"
  refute_file_exists "$VDM_REPO_PATH/joomla/.clone.lock"
}

@test "migration package: source hardlinks are refused before downtime" {
  ln "$VDM_PROJECT_PATH/source/db/ibdata1" "$VDM_PROJECT_PATH/source/db/hardlink"
  run exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  assert_failure
  refute_command '^docker stop '
}

@test "migration package: does not overwrite an existing archive" {
  printf 'existing\n' > "$SANDBOX/project.tar.gz"
  run exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  assert_failure
  assert_file_contains "$SANDBOX/project.tar.gz" existing
  refute_command '^docker stop '
}

@test "migration archive: refuses symbolic links before extracting" {
  mkdir "$SANDBOX/bad"
  ln -s /etc "$SANDBOX/bad/escape"
  tar -czf "$SANDBOX/bad.tar.gz" -C "$SANDBOX/bad" .
  run migrationValidateTar "$SANDBOX/bad.tar.gz" folder
  assert_failure
}

@test "migration archive: refuses hard links and traversal" {
  mkdir "$SANDBOX/bad"
  printf x > "$SANDBOX/bad/original"
  ln "$SANDBOX/bad/original" "$SANDBOX/bad/linked"
  tar -czf "$SANDBOX/hardlinks.tar.gz" -C "$SANDBOX/bad" .
  run migrationValidateTar "$SANDBOX/hardlinks.tar.gz" folder
  assert_failure
  if tar --version | grep -q 'GNU tar'; then
    tar --transform='s|original|../escape|' -czf "$SANDBOX/traversal.tar.gz" -C "$SANDBOX/bad" original
  else
    tar -s ',original,../escape,' -czf "$SANDBOX/traversal.tar.gz" -C "$SANDBOX/bad" original
  fi
  run migrationValidateTar "$SANDBOX/traversal.tar.gz" folder
  assert_failure
}

@test "migration archive: refuses embedded newlines and privileged file modes" {
  mkdir "$SANDBOX/bad"
  printf x > "$SANDBOX/bad/unsafe"$'\n'"name"
  tar -czf "$SANDBOX/newline.tar.gz" -C "$SANDBOX/bad" .
  run migrationValidateTar "$SANDBOX/newline.tar.gz" folder
  assert_failure
  printf x > "$SANDBOX/bad/executable"
  chmod 4755 "$SANDBOX/bad/executable"
  tar -czf "$SANDBOX/setuid.tar.gz" -C "$SANDBOX/bad" executable
  run migrationValidateTar "$SANDBOX/setuid.tar.gz" folder
  assert_failure
}

@test "migration manifest: refuses unknown or duplicate settings without changing globals" {
  exportJoomlaMigration source.example.org "$SANDBOX/project.tar.gz"
  mkdir -m 700 "$SANDBOX/unpacked"
  extractJoomlaMigration "$SANDBOX/project.tar.gz" "$SANDBOX/unpacked"
  printf 'VDM_PROJECT_PATH=/outside\n' >> "$SANDBOX/unpacked/manifest.env"
  original="$VDM_PROJECT_PATH"
  run migrationValidateManifest "$SANDBOX/unpacked/manifest.env"
  assert_failure
  assert_equal "$VDM_PROJECT_PATH" "$original"
}

@test "migration scoped env: refuses env values not referenced by Compose" {
  run migrationValidateScopedEnv "$PACKAGE_SOURCE/docker-compose.yml" "$VDM_REPO_PATH/joomla/.env"
  assert_failure
}

@test "migration scoped env: refuses interpolation unsupported by identity rewriting" {
  printf 'environment:\n  - PASSWORD=$VDM_SOURCE_DB_PASS\n' > "$SANDBOX/unbraced.yml"
  run migrationComposeReferences "$SANDBOX/unbraced.yml"
  assert_failure
  printf 'environment:\n  - PASSWORD=${VDM_SOURCE_DB_PASS:-fallback}\n' > "$SANDBOX/default.yml"
  run migrationComposeReferences "$SANDBOX/default.yml"
  assert_failure
}
