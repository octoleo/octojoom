#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  TMPDIR="$SANDBOX/tmp"
  mkdir "$TMPDIR"
  export TMPDIR
  command -v jq >/dev/null || skip 'jq is required for backup tests'
  VDM_CONTAINER_TYPE=joomla
  OCTOJOOM_NON_INTERACTIVE=true
  OCTOJOOM_OUTPUT=text
  make_joomla_container alpha ALPHA first
  local root="$VDM_PROJECT_PATH/alpha/joomla"
  printf 'uploaded bytes\n' > "$root/upload.txt"
  cat > "$root/configuration.php" <<'PHP'
<?php
class JConfig {
 public $host = 'mariadbalpha';
 public $dbtype = 'mysqli';
 public $db = 'alpha_db';
 public $user = 'alpha_user';
 public $password = 'secret';
 public $dbprefix = 'abc_';
 public $live_site = '';
 public $cookie_domain = '';
 public $force_ssl = 0;
}
PHP
  chmod 640 "$root/upload.txt"
  BACKUP_MODEL="$SANDBOX/model.json"
  MSYS2_ARG_CONV_EXCL='*' jq -n --arg root "$root" --arg db "$VDM_PROJECT_PATH/alpha/db" '{services:{joomlaalpha:{image:"joomla:latest",environment:{JOOMLA_DB_HOST:"mariadbalpha",JOOMLA_DB_NAME:"alpha_db",JOOMLA_DB_USER:"alpha_user",JOOMLA_DB_PASSWORD:"secret"},volumes:[{type:"bind",source:$root,target:"/var/www/html"}]},mariadbalpha:{image:"mariadb:latest",volumes:[{type:"bind",source:$db,target:"/var/lib/mysql"}]}}}' > "$BACKUP_MODEL"
  BACKUP_CALLS="$SANDBOX/backup-calls"
  BACKUP_RUNNING=$'joomlaalpha\nmariadbalpha'
  BACKUP_DUMP_STATUS=0
  BACKUP_STOP_STATUS=0
  joomlaSiteCompose() {
    local site="$1"; shift
    printf '%s %s\n' "$site" "$*" >> "$BACKUP_CALLS"
    case "$*" in
      'config --format json') cat "$BACKUP_MODEL";;
      'ps --status running --services') printf '%s\n' "$BACKUP_RUNNING";;
      'stop '*) return "$BACKUP_STOP_STATUS";;
      'ps --all --quiet') return 0;;
      *) return 0;;
    esac
  }
  joomlaDatabaseContext() {
    VDM_DB_ENGINE=mariadb VDM_DB_PREFIX=abc_ VDM_DB_SERVICE=mariadbalpha
    VDM_DB_NAME=alpha_db VDM_DB_USER=alpha_user VDM_DB_PASSWORD=secret VDM_DB_HOST=mariadbalpha
  }
  joomlaDatabaseVerifyConnection() { return 0; }
  joomlaDatabaseExport() {
    printf 'dump %s\n' "$1" >> "$BACKUP_CALLS"
    printf 'CREATE TABLE abc_test (id INT);\nINSERT INTO abc_test VALUES (7);\n' > "$2"
    return "$BACKUP_DUMP_STATUS"
  }
  BACKUP_DIRECTORY="$SANDBOX/backups with spaces"
  mkdir "$BACKUP_DIRECTORY"
}

@test "full tar backup preserves selected files SQL private scoped environment and source state" {
  run joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/full.tar.gz" full tar.gz false
  assert_success
  assert_file_exists "$BACKUP_DIRECTORY/full.tar.gz.sha256"
  local stage="$SANDBOX/extracted"
  mkdir "$stage"
  joomlaBackupExtract "$BACKUP_DIRECTORY/full.tar.gz" "$stage"
  cmp "$VDM_PROJECT_PATH/alpha/joomla/upload.txt" "$stage/project/joomla/upload.txt"
  grep -q 'CREATE TABLE abc_test' "$stage/project/database.sql"
  grep -q '^VDM_ALPHA_DB_PASS=' "$stage/compose/.env"
  run grep -q 'VDM_BETA_' "$stage/compose/.env"
  assert_failure
  grep -q 'first.vdm.dev stop joomlaalpha' "$BACKUP_CALLS"
  grep -q 'first.vdm.dev start joomlaalpha' "$BACKUP_CALLS"
  [ ! -e "$VDM_REPO_PATH/joomla/enabled/first.vdm.dev" ]
  if ! is_windows; then
    assert_equal "$(file_mode "$BACKUP_DIRECTORY/full.tar.gz")" 600
    assert_equal "$(file_mode "$stage/project/joomla/upload.txt")" 640
  fi
}

@test "website ZIP contains SQL and restores payload metadata" {
  command -v zip >/dev/null && command -v unzip >/dev/null || skip 'zip tools unavailable'
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/website.zip" website zip false >/dev/null
  mkdir "$SANDBOX/zip-restore"
  joomlaBackupExtract "$BACKUP_DIRECTORY/website.zip" "$SANDBOX/zip-restore"
  cmp "$VDM_PROJECT_PATH/alpha/joomla/upload.txt" "$SANDBOX/zip-restore/project/joomla/upload.txt"
  [ -s "$SANDBOX/zip-restore/project/database.sql" ]
  if ! is_windows; then assert_equal "$(file_mode "$SANDBOX/zip-restore/project/joomla/upload.txt")" 640; fi
}

@test "files-only scope explicitly excludes SQL and never exports database" {
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/files.tar.gz" files tar.gz false >/dev/null
  mkdir "$SANDBOX/files-restore"
  joomlaBackupExtract "$BACKUP_DIRECTORY/files.tar.gz" "$SANDBOX/files-restore"
  [ ! -e "$SANDBOX/files-restore/project/database.sql" ]
  run grep -q '^dump ' "$BACKUP_CALLS"
  assert_failure
  grep -q 'VDM_MIGRATION_SCOPE=.*files' "$SANDBOX/files-restore/manifest.env"
}

@test "database scope includes prefix and SQL without application files" {
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/database.tar.gz" database tar.gz false >/dev/null
  mkdir "$SANDBOX/database-restore"
  joomlaBackupExtract "$BACKUP_DIRECTORY/database.tar.gz" "$SANDBOX/database-restore"
  [ -s "$SANDBOX/database-restore/project/database.sql" ]
  [ ! -e "$SANDBOX/database-restore/project/joomla" ]
  local prefix
  migrationReadEnvValue "$SANDBOX/database-restore/manifest.env" VDM_MIGRATION_DB_PREFIX prefix
  assert_equal "$prefix" abc_
}

@test "partial database export is not published and source running set is resumed" {
  BACKUP_DUMP_STATUS=28
  run joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/partial.tar.gz" full tar.gz false
  assert_status 28
  [ ! -e "$BACKUP_DIRECTORY/partial.tar.gz" ]
  [ ! -e "$VDM_REPO_PATH/joomla/available/first.vdm.dev/.octojoom-change.lock" ]
  grep -q 'first.vdm.dev start joomlaalpha' "$BACKUP_CALLS"
}

@test "compression failure preserves the previous successful archive" {
  printf 'prior archive' > "$BACKUP_DIRECTORY/prior.tar.gz"
  # Exercise Unix privilege delegation through the sandboxed sudo stand-in.
  OS_NUMBER=1
  hook_command sudo <<'HOOK'
case "$*" in *'tar --numeric-owner -czf'*) exit 24;; esac
HOOK
  run joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/prior.tar.gz" full tar.gz true
  assert_status 24
  assert_equal "$(cat "$BACKUP_DIRECTORY/prior.tar.gz")" 'prior archive'
  grep -q 'first.vdm.dev start joomlaalpha' "$BACKUP_CALLS"
}

@test "existing archive needs explicit overwrite before source changes" {
  printf 'prior archive' > "$BACKUP_DIRECTORY/prior.tar.gz"
  run joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/prior.tar.gz" full tar.gz false
  assert_status 17
  assert_equal "$(cat "$BACKUP_DIRECTORY/prior.tar.gz")" 'prior archive'
  [ ! -e "$BACKUP_CALLS" ]
}

@test "stopped source database is started only for export then stopped again" {
  BACKUP_RUNNING=''
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/stopped.tar.gz" database tar.gz false >/dev/null
  grep -q 'first.vdm.dev up -d --no-deps mariadbalpha' "$BACKUP_CALLS"
  grep -q 'first.vdm.dev stop mariadbalpha' "$BACKUP_CALLS"
  run grep -q 'first.vdm.dev start joomlaalpha' "$BACKUP_CALLS"
  assert_failure
}

@test "backup captures root-level relative companion config and rejects external dependencies" {
  printf 'php override' > "$VDM_REPO_PATH/joomla/available/first.vdm.dev/custom.ini"
  jq --arg source "$VDM_REPO_PATH/joomla/available/first.vdm.dev/custom.ini" '.services.joomlaalpha.volumes += [{type:"bind",source:$source,target:"/usr/local/etc/php/conf.d/custom.ini",read_only:true}]' "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/companion.tar.gz" full tar.gz false >/dev/null
  mkdir "$SANDBOX/companion-restore"
  joomlaBackupExtract "$BACKUP_DIRECTORY/companion.tar.gz" "$SANDBOX/companion-restore"
  assert_equal "$(cat "$SANDBOX/companion-restore/compose/custom.ini")" 'php override'
  jq '.services.joomlaalpha.volumes[1].source="/unrelated/private/config"' "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  run joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/external.tar.gz" full tar.gz false
  assert_failure
  [ ! -e "$BACKUP_DIRECTORY/external.tar.gz" ]
}

@test "transport digest mismatch prevents extracting a restore point" {
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/digest.tar.gz" full tar.gz false >/dev/null
  printf '%064d\n' 0 > "$BACKUP_DIRECTORY/digest.tar.gz.sha256"
  mkdir "$SANDBOX/corrupt-restore"
  run joomlaBackupExtract "$BACKUP_DIRECTORY/digest.tar.gz" "$SANDBOX/corrupt-restore"
  assert_failure
  [ ! -e "$SANDBOX/corrupt-restore/manifest.env" ]
}

@test "ZIP links are rejected before extraction" {
  skip_on_windows 'native symlinks unavailable'
  command -v zip >/dev/null && command -v unzip >/dev/null || skip 'zip tools unavailable'
  mkdir -p "$SANDBOX/unsafe/project"
  ln -s /tmp "$SANDBOX/unsafe/project/escape"
  (cd "$SANDBOX/unsafe" && zip -qry "$BACKUP_DIRECTORY/unsafe.zip" project)
  run joomlaBackupValidateArchive "$BACKUP_DIRECTORY/unsafe.zip"
  assert_failure
}

@test "inventory identifies actual scope format and selected site only" {
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/first.tar.gz" database tar.gz false >/dev/null
  run joomlaBackupList first.vdm.dev "$BACKUP_DIRECTORY"
  assert_success
  assert_output_contains $'database\ttar.gz'
  run joomlaBackupList second.vdm.dev "$BACKUP_DIRECTORY"
  assert_success
  assert_equal "$output" ''
}

@test "timestamp disabled and labels generate stable distinct site filenames" {
  VDM_DESTINATION="$BACKUP_DIRECTORY" VDM_SCOPE=website VDM_FORMAT=zip VDM_LABEL='before change' VDM_TIMESTAMP=false
  assert_equal "$(joomlaBackupFilename first.vdm.dev)" "$BACKUP_DIRECTORY/first.vdm.dev-website-before-change.zip"
  assert_equal "$(joomlaBackupFilename second.vdm.dev)" "$BACKUP_DIRECTORY/second.vdm.dev-website-before-change.zip"
}

@test "retention defaults to no deletion and keeps the requested newest backups" {
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/one.tar.gz" database tar.gz false >/dev/null
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/two.tar.gz" database tar.gz false >/dev/null
  VDM_CONFIRM=true VDM_DESTINATION="$BACKUP_DIRECTORY"
  joomlaBackupCleanup first.vdm.dev "$BACKUP_DIRECTORY" 0
  [ -f "$BACKUP_DIRECTORY/one.tar.gz" ] && [ -f "$BACKUP_DIRECTORY/two.tar.gz" ]
  joomlaBackupCleanup first.vdm.dev "$BACKUP_DIRECTORY" 1 >/dev/null
  local archives=("$BACKUP_DIRECTORY/"*.tar.gz)
  assert_equal "${#archives[@]}" 1
}

@test "current restore rejects unverified archive before stopping selected services" {
  printf 'invalid archive' > "$BACKUP_DIRECTORY/invalid.tar.gz"
  run joomlaBackupRestoreCurrent first.vdm.dev "$BACKUP_DIRECTORY/invalid.tar.gz"
  assert_failure
  run grep -q 'first.vdm.dev stop' "$BACKUP_CALLS"
  assert_failure
}

@test "destination validation refuses external bind paths and existing named volumes" {
  run joomlaBackupValidateDestination '{"services":{"web":{"volumes":[{"type":"bind","source":"/outside/secret","target":"/var/www/html"}]}}}' "$SANDBOX/project" "$SANDBOX/site" true
  assert_failure
  docker() { return 0; }
  run joomlaBackupValidateDestination '{"services":{"web":{"volumes":[{"type":"volume","source":"data","target":"/var/www/html"}]}},"volumes":{"data":{"name":"other-site-data"}}}' "$SANDBOX/project" "$SANDBOX/site" true
  assert_failure
}

@test "named website volume is validated before host extraction and retains its contents" {
  jq '.services.joomlaalpha.volumes[0]={type:"volume",source:"alpha_web",target:"/var/www/html"}|.volumes={alpha_web:{name:"actual_alpha_web"}}' "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  docker() {
    case "$*" in
      'volume inspect actual_alpha_web') return 0;;
      'run '*'-czpf - -C /octojoom-site .') command tar -czpf - -C "$VDM_PROJECT_PATH/alpha/joomla" .;;
      *) return 0;;
    esac
  }
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/volume.tar.gz" full tar.gz false >/dev/null
  mkdir "$SANDBOX/volume-restore"
  joomlaBackupExtract "$BACKUP_DIRECTORY/volume.tar.gz" "$SANDBOX/volume-restore"
  cmp "$VDM_PROJECT_PATH/alpha/joomla/upload.txt" "$SANDBOX/volume-restore/project/joomla/upload.txt"
}

@test "failed current-site import restores previous configuration and leaves original files untouched" {
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/rollback.tar.gz" website tar.gz false >/dev/null
  printf 'newer live upload\n' > "$VDM_PROJECT_PATH/alpha/joomla/upload.txt"
  local compose="$VDM_REPO_PATH/joomla/available/first.vdm.dev/docker-compose.yml"
  cp "$compose" "$SANDBOX/compose.before"
  joomlaDatabaseCopyConfiguration() { cp "$VDM_PROJECT_PATH/alpha/joomla/configuration.php" "$2"; }
  siteValidateCompose() { return 0; }
  joomlaDatabaseStageStorage() {
    VDM_DATABASE_STAGE_COMPOSE="$4/docker-compose.yml" VDM_DATABASE_STAGE_ENV="$4/.env"
    cp "$compose" "$VDM_DATABASE_STAGE_COMPOSE"
    cp "$VDM_REPO_PATH/joomla/available/first.vdm.dev/.env" "$VDM_DATABASE_STAGE_ENV"
    printf 'fresh database storage prepared\n' >> "$BACKUP_CALLS"
  }
  joomlaDatabaseImport() { printf 'candidate import failed\n' >> "$BACKUP_CALLS"; return 31; }
  run joomlaBackupRestoreCurrent first.vdm.dev "$BACKUP_DIRECTORY/rollback.tar.gz"
  assert_status 31
  cmp "$compose" "$SANDBOX/compose.before"
  assert_equal "$(cat "$VDM_PROJECT_PATH/alpha/joomla/upload.txt")" 'newer live upload'
  [ ! -e "$VDM_REPO_PATH/joomla/available/first.vdm.dev/.env" ]
  [ ! -e "$VDM_REPO_PATH/joomla/available/first.vdm.dev/.octojoom-change.lock" ]
  grep -q 'candidate import failed' "$BACKUP_CALLS"
  grep -q 'first.vdm.dev start joomlaalpha' "$BACKUP_CALLS"
  assert_output_contains 'original deployment/storage were restored'
}

@test "deletion rejects another directory and another site's archive" {
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/owned.tar.gz" database tar.gz false >/dev/null
  VDM_CONFIRM=true VDM_DESTINATION="$SANDBOX"
  run joomlaBackupDelete first.vdm.dev "$BACKUP_DIRECTORY/owned.tar.gz"
  assert_status 17
  VDM_DESTINATION="$BACKUP_DIRECTORY"
  run joomlaBackupDelete second.vdm.dev "$BACKUP_DIRECTORY/owned.tar.gz"
  assert_status 17
  [ -f "$BACKUP_DIRECTORY/owned.tar.gz" ]
}

@test "full current restore writes literal dollar credentials from serialized Compose exactly once" {
  local secret='literal-$single-$$pair-${braces}' serialized compose
  serialized="${secret//\$/\$\$}"
  jq --arg value "$serialized" '.services.joomlaalpha.environment.JOOMLA_DB_PASSWORD=$value' "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  writeEnvVariable "$VDM_REPO_PATH/joomla/.env" "VDM_ALPHA_DB_PASS=\"$secret\"" true
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/literal.tar.gz" full tar.gz false >/dev/null
  compose="$VDM_REPO_PATH/joomla/available/first.vdm.dev/docker-compose.yml"
  joomlaDatabaseCopyConfiguration() { cp "$VDM_PROJECT_PATH/alpha/joomla/configuration.php" "$2"; }
  migrationRunCompose() { cat "$BACKUP_MODEL"; }
  siteValidateCompose() { return 0; }
  joomlaDatabaseStageStorage() {
    VDM_DATABASE_STAGE_COMPOSE="$4/docker-compose.yml" VDM_DATABASE_STAGE_ENV="$4/.env"
    cp "$compose" "$VDM_DATABASE_STAGE_COMPOSE"
    cp "$VDM_REPO_PATH/joomla/available/first.vdm.dev/.env" "$VDM_DATABASE_STAGE_ENV"
  }
  joomlaDatabaseImport() { return 0; }
  joomlaBackupVerifyApplication() { return 0; }
  run joomlaBackupRestoreCurrent first.vdm.dev "$BACKUP_DIRECTORY/literal.tar.gz"
  assert_success
  local restored=("$VDM_REPO_PATH/joomla/available/first.vdm.dev/"restore-data-*/configuration.php)
  assert_equal "${#restored[@]}" 1
  assert_equal "$(getJoomlaConfigValue "${restored[0]}" password)" "$secret"
  refute_output_contains "$secret"
}

@test "destination validation accepts contained absolute binds and rejects path aliases" {
  local model
  model=$(MSYS2_ARG_CONV_EXCL='*' jq -n --arg source "$SANDBOX/project/joomla" '{services:{web:{volumes:[{type:"bind",source:$source,target:"/var/www/html"}]}}}')
  run joomlaBackupValidateDestination "$model" "$SANDBOX/project" "$SANDBOX/site" true
  assert_success
  model=$(MSYS2_ARG_CONV_EXCL='*' jq -n --arg source "$SANDBOX/project//joomla" '{services:{web:{volumes:[{type:"bind",source:$source,target:"/var/www/html"}]}}}')
  run joomlaBackupValidateDestination "$model" "$SANDBOX/project" "$SANDBOX/site" true
  assert_failure
}

@test "Windows backup copies native website companion and config paths through filesystem guards" {
  OS_NUMBER=3
  cygpath() {
    [ "$1" = -au ] && [ "$2" = -- ] || return 1
    printf '%s\n' "${3#C:}"
  }
  local directory="$VDM_REPO_PATH/joomla/available/first.vdm.dev"
  printf 'php override' > "$directory/custom.ini"
  printf 'private config' > "$directory/app.conf"
  MSYS2_ARG_CONV_EXCL='*' jq --arg directory "$directory" '
    (.services[].volumes[].source) |= ("C:" + .) |
    .services.joomlaalpha.volumes += [{type:"bind",source:("C:"+$directory+"/custom.ini"),target:"/usr/local/etc/php/conf.d/custom.ini",read_only:true}] |
    .configs={app:{file:("C:"+$directory+"/app.conf")}}
  ' < "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/native.tar.gz" full tar.gz false >/dev/null
  mkdir "$SANDBOX/native-restore"
  joomlaBackupExtract "$BACKUP_DIRECTORY/native.tar.gz" "$SANDBOX/native-restore"
  assert_equal "$(cat "$SANDBOX/native-restore/compose/custom.ini")" 'php override'
  assert_equal "$(cat "$SANDBOX/native-restore/compose/app.conf")" 'private config'
  cmp "$VDM_PROJECT_PATH/alpha/joomla/upload.txt" "$SANDBOX/native-restore/project/joomla/upload.txt"
}

@test "Windows destination checks normalize host aliases without concealing traversal" {
  OS_NUMBER=3
  cygpath() {
    [ "$1" = -au ] && [ "$2" = -- ] || return 1
    printf '%s\n' "${3#C:}"
  }
  local model
  model=$(MSYS2_ARG_CONV_EXCL='*' jq -n --arg project "C:$SANDBOX/project" --arg site "C:$SANDBOX/site" '{services:{web:{volumes:[{type:"bind",source:($project+"/joomla"),target:"/var/www/html"}]}},configs:{app:{file:($site+"/app.conf")}}}')
  run joomlaBackupValidateDestination "$model" "$SANDBOX/project" "$SANDBOX/site" true
  assert_success
  model=$(printf '%s' "$model" | jq '.services.web.volumes[0].source += "/../outside"')
  run joomlaBackupValidateDestination "$model" "$SANDBOX/project" "$SANDBOX/site" true
  assert_failure
  model=$(printf '%s' "$model" | jq '.services.web.volumes[0].source="C:/unrelated/private"')
  run joomlaBackupValidateDestination "$model" "$SANDBOX/project" "$SANDBOX/site" true
  assert_failure
}

@test "named-volume archive realigns without an unreferenced source project path" {
  local compose="$VDM_REPO_PATH/joomla/available/first.vdm.dev/docker-compose.yml"
  sed -e 's#${VDM_PROJECT_PATH}/alpha/joomla#alpha_web#g' -e 's#${VDM_PROJECT_PATH}/alpha/db#alpha_db#g' "$compose" > "$compose.next"
  mv "$compose.next" "$compose"
  printf '\nvolumes:\n  alpha_web:\n  alpha_db:\n' >> "$compose"
  jq '.services.joomlaalpha.volumes[0]={type:"volume",source:"alpha_web",target:"/var/www/html"} |
    .services.mariadbalpha.volumes[0]={type:"volume",source:"alpha_db",target:"/var/lib/mysql"} |
    .volumes={alpha_web:{name:"actual_alpha_web"},alpha_db:{name:"actual_alpha_db"}}' < "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  docker() {
    case "$*" in
      'volume inspect actual_alpha_web') return 0;;
      'run '*'-czpf - -C /octojoom-site .') command tar -czpf - -C "$VDM_PROJECT_PATH/alpha/joomla" .;;
      *) return 0;;
    esac
  }
  siteWriteScopedEnv "$compose" "$VDM_REPO_PATH/joomla/.env" ALPHA "${compose%/*}/.env"
  joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/named.tar.gz" full tar.gz false >/dev/null
  local package="$SANDBOX/named-restore"
  mkdir "$package"
  joomlaBackupExtract "$BACKUP_DIRECTORY/named.tar.gz" "$package"
  run grep -q '^VDM_PROJECT_PATH=' "$package/compose/.env"
  assert_failure
  migrationRunCompose() { cat "$BACKUP_MODEL"; }
  joomlaBackupPortableCompose "$package" alpha alpha
  run grep -q 'actual_alpha_web\|actual_alpha_db' "$package/compose/docker-compose.yml"
  assert_failure
  rewriteJoomlaComposeIdentity "$package/compose/docker-compose.yml" "$package/compose/renamed.yml" alpha beta ALPHA BETA first second vdm.dev vdm.dev alpha
  grep -q 'beta_web:/var/www/html' "$package/compose/renamed.yml"
  grep -q 'beta_db:/var/lib/mysql' "$package/compose/renamed.yml"
  run grep -q 'alpha_web\|alpha_db' "$package/compose/renamed.yml"
  assert_failure
  jq '.services.joomlaalpha.volumes += [{type:"bind",source:"/unrelated/private",target:"/extra"}]' < "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  run joomlaBackupPortableCompose "$package" alpha alpha
  assert_failure
  assert_output_contains 'cannot be mapped into destination storage'
  jq 'del(.services.joomlaalpha.volumes[1]) | .volumes.alpha_web.driver_opts={device:"/source/website"}' < "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  run joomlaBackupPortableCompose "$package" alpha alpha
  assert_failure
  assert_output_contains 'cannot realign external or custom-driver volume storage'
}

@test "independent restore removes unused managed source volume declarations" {
  local package="$SANDBOX/managed-volume-package" compose
  mkdir -p "$package/compose"
  compose="$package/compose/docker-compose.yml"
  cp "$VDM_REPO_PATH/joomla/available/first.vdm.dev/docker-compose.yml" "$compose"
  cp "$VDM_REPO_PATH/joomla/.env" "$package/compose/.env"
  joomlaBackupReplaceMount "$compose" "$compose.next" mariadbalpha /var/lib/mysql octojoom_alpha_db_saved
  mv "$compose.next" "$compose"
  printf '\nvolumes:\n  octojoom_alpha_db_saved:\n    name: octojoom_alpha_db_saved\n  octojoom_alpha_db_older:\n    name: octojoom_alpha_db_older\n' >> "$compose"
  jq '.services.mariadbalpha.volumes[0]={type:"volume",source:"octojoom_alpha_db_saved",target:"/var/lib/mysql"} |
    .volumes={octojoom_alpha_db_saved:{name:"octojoom_alpha_db_saved"},octojoom_alpha_db_older:{name:"octojoom_alpha_db_older"}}' < "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  migrationRunCompose() { cat "$BACKUP_MODEL"; }
  joomlaBackupPortableCompose "$package" alpha alpha
  rewriteJoomlaComposeIdentity "$compose" "$package/compose/renamed.yml" alpha beta ALPHA BETA first second vdm.dev vdm.dev alpha
  assert_file_contains "$package/compose/renamed.yml" '/beta/db:/var/lib/mysql'
  run grep -q 'octojoom_alpha_db\|^volumes:' "$package/compose/renamed.yml"
  assert_failure
}

@test "managed absolute website and named database support scoped backups and another current restore" {
  local directory="$VDM_REPO_PATH/joomla/available/first.vdm.dev" scope
  local compose="$directory/docker-compose.yml"
  BACKUP_ABSOLUTE_ROOT="$directory/restore-data-existing"
  cp -a "$VDM_PROJECT_PATH/alpha/joomla" "$BACKUP_ABSOLUTE_ROOT"
  joomlaBackupReplaceMount "$compose" "$compose.next" joomlaalpha /var/www/html "$BACKUP_ABSOLUTE_ROOT"
  mv "$compose.next" "$compose"
  joomlaBackupReplaceMount "$compose" "$compose.next" mariadbalpha /var/lib/mysql alpha_candidate_db
  mv "$compose.next" "$compose"
  printf '\nvolumes:\n  alpha_candidate_db:\n    name: alpha_candidate_db\n' >> "$compose"
  MSYS2_ARG_CONV_EXCL='*' jq --arg root "$BACKUP_ABSOLUTE_ROOT" '
    .services.joomlaalpha.volumes[0].source=$root |
    .services.mariadbalpha.volumes[0]={type:"volume",source:"alpha_candidate_db",target:"/var/lib/mysql"} |
    .volumes={alpha_candidate_db:{name:"alpha_candidate_db"}}
  ' < "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  siteWriteScopedEnv "$compose" "$VDM_REPO_PATH/joomla/.env" ALPHA "$directory/.env"
  run grep -q '^VDM_PROJECT_PATH=' "$directory/.env"
  assert_failure
  for scope in full website; do
    joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/managed-$scope.tar.gz" "$scope" tar.gz false >/dev/null
  done
  mkdir "$SANDBOX/managed-extracted"
  joomlaBackupExtract "$BACKUP_DIRECTORY/managed-full.tar.gz" "$SANDBOX/managed-extracted"
  cmp "$BACKUP_ABSOLUTE_ROOT/upload.txt" "$SANDBOX/managed-extracted/project/joomla/upload.txt"
  jq '.services.joomlaalpha.volumes += [{type:"bind",source:"/unrelated/private",target:"/extra"}]' < "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  run joomlaBackupCreate first.vdm.dev "$BACKUP_DIRECTORY/managed-external.tar.gz" full tar.gz false
  assert_failure
  assert_output_contains 'Required external mount is not site-local'
  jq 'del(.services.joomlaalpha.volumes[1])' < "$BACKUP_MODEL" > "$BACKUP_MODEL.next"
  mv "$BACKUP_MODEL.next" "$BACKUP_MODEL"
  joomlaDatabaseCopyConfiguration() { cp "$BACKUP_ABSOLUTE_ROOT/configuration.php" "$2"; }
  migrationRunCompose() { cat "$BACKUP_MODEL"; }
  siteValidateCompose() { return 0; }
  joomlaDatabaseStageStorage() {
    VDM_DATABASE_STAGE_COMPOSE="$4/docker-compose.yml" VDM_DATABASE_STAGE_ENV="$4/.env"
    cp "$compose" "$VDM_DATABASE_STAGE_COMPOSE"
    cp "$VDM_REPO_PATH/joomla/available/first.vdm.dev/.env" "$VDM_DATABASE_STAGE_ENV"
  }
  joomlaDatabaseImport() { return 0; }
  joomlaBackupVerifyApplication() { return 0; }
  run joomlaBackupRestoreCurrent first.vdm.dev "$BACKUP_DIRECTORY/managed-full.tar.gz"
  assert_success
  local restored=("$directory/"restore-data-*/configuration.php)
  assert_equal "${#restored[@]}" 2
  [ -f "$BACKUP_ABSOLUTE_ROOT/upload.txt" ]
  [ ! -e "$directory/.octojoom-change.lock" ]
}
