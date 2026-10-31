#!/usr/bin/env bats
# Progress integration must not change Compose commands, output or failure status.
# shellcheck disable=SC2034,SC2154,SC2317

load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  make_joomla_container abc ABC abc
  PROGRESS_CALLS="$SANDBOX/progress.calls"
  : > "$PROGRESS_CALLS"
  runActionProgress() {
    printf '%s\n%s\n' "$1" "$2" >> "$PROGRESS_CALLS"
    shift 2
    "$@"
  }
}

@test "Compose mutations show progress and preserve the exact argument boundaries" {
  docker() { printf '%s\n' "$@" > "$SANDBOX/arguments"; return 19; }
  run runComposeProgress '/a path/config.yml' compose --env-file '/env path/.env' --file '/a path/config.yml' --project-directory '/project path' up -d --wait
  assert_status 19
  grep -q 'Preparing images' "$PROGRESS_CALLS"
  assert_equal "$(sed -n '3p' "$SANDBOX/arguments")" '/env path/.env'
  assert_equal "$(sed -n '5p' "$SANDBOX/arguments")" '/a path/config.yml'
  assert_equal "$(sed -n '7p' "$SANDBOX/arguments")" '/project path'
  assert_equal "$(sed -n '8p' "$SANDBOX/arguments")" up
  assert_equal "$(wc -l < "$SANDBOX/arguments" | tr -d ' ')" 10
}

@test "read-only Compose commands bypass progress even when option values resemble mutations" {
  docker() { printf '{"services":{}}\n'; }
  run runComposeProgress config.yml compose --file up --env-file restart --project-name stop config --format json
  assert_success
  assert_equal "$output" '{"services":{}}'
  [ ! -s "$PROGRESS_CALLS" ]
  run runComposeProgress config.yml compose --file=config.yml exec -T application echo up
  assert_success
  [ ! -s "$PROGRESS_CALLS" ]
}

@test "lifecycle and transaction Compose wrappers retain native failures with one progress session" {
  local file="$VDM_REPO_PATH/joomla/available/abc.vdm.dev/docker-compose.yml"
  fail_command docker-compose-up 23
  VDM_CONTAINER=abc.vdm.dev
  link_enabled joomla abc.vdm.dev
  run joomlaSiteLifecycle redeploy
  assert_status 23
  assert_equal "$(grep -c '^Docker Compose$' "$PROGRESS_CALLS")" 1
  : > "$PROGRESS_CALLS"
  run migrationRunCompose '' "$file" --project-directory "${file%/*}" up -d --wait
  assert_status 23
  assert_equal "$(grep -c '^Docker Compose$' "$PROGRESS_CALLS")" 1
  refute_command 'compose --env-file  '
}

@test "permission progress finishes the failing command before reporting failure" {
  permission_command() { printf 'finished\n' > "$SANDBOX/finished"; return 14; }
  run runPermissionProgress 'Changing permissions' permission_command
  assert_status 14
  assert_file_exists "$SANDBOX/finished"
  assert_dialog 'permission update failed'
  refute_file_exists "$VDM_SRC_PATH/.progress"
}

@test "backup progress preserves archive output and does not report a failed worker as success" {
  joomlaBackupCreateAction() { printf '%s\n' "$2"; return 16; }
  run joomlaBackupCreate abc.vdm.dev '/backup path/archive.tar.gz' full
  assert_status 16
  assert_equal "$output" '/backup path/archive.tar.gz'
  grep -q 'Backup | abc.vdm.dev' "$PROGRESS_CALLS"
}

@test "image inspection progress leaves JSON output intact" {
  docker() { printf '{"php":"8.3.1","joomla":"5.2.0","flavor":"apache"}\n'; }
  run joomlaRuntimeProbeImage joomla:5.2-php8.3-apache
  assert_success
  assert_equal "$output" '{"php":"8.3.1","joomla":"5.2.0","flavor":"apache"}'
  grep -q 'Inspect PHP image' "$PROGRESS_CALLS"
}

@test "restore menu result stays machine readable without suppressing interactive progress" {
  VDM_ACTION=restore VDM_TARGET=new VDM_KEY=newkey VDM_TARGET_HOST=new.vdm.dev
  VDM_FILE="$SANDBOX/backup.tar.gz"
  : > "$VDM_FILE"
  OCTOJOOM_BACKUP_RESULT_JSON=true
  unset OCTOJOOM_OUTPUT
  joomlaBackupVerify() { [ "${OCTOJOOM_OUTPUT:-text}" = text ]; }
  joomlaBackupRestoreNewAction() { [ "${OCTOJOOM_OUTPUT:-text}" = text ]; }
  run joomla__TRuST__backup
  assert_success
  assert_equal "$(printf '%s' "$output" | jq -r .destination_site)" new.vdm.dev
  grep -q 'Restore | new.vdm.dev' "$PROGRESS_CALLS"
}
