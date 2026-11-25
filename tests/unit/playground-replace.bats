#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  bats_require_minimum_version 1.5.0
  octojoom_setup
  octojoom_config
  package="$SANDBOX/Shop's \$5 export.zip"
  prepared="$SANDBOX/prepared"
  site=shop.example.test
  make_joomla_container shop SHOP shop example.test
  write_playground_fixture "$package" fresh
}

# Record only the routing decision; the destructive operation has its own
# tests. Leaving the real CLI and whiptail dispatch in place catches bypasses.
record_replace() {
  joomlaPlaygroundDeployCurrent() {
    [ "$1" = "$package" ] && [ "$2" = "$site" ] || return 91
    printf '%s\n' "$3" "${4:-}" > "$SANDBOX/decision"
    printf '{"site":"%s","backup":%s}\n' "$2" "$3"
  }
}

replace_cli() {
  cliStart --type joomla --task playground --action deploy --target current --file "$package" \
    --non-interactive --output json "$@"
}

@test "replacement CLI requires an explicit site, replacement consent and a separate backup waiver" {
  record_replace
  run --separate-stderr replace_cli --confirm yes
  assert_status 17
  run --separate-stderr replace_cli --container "$site"
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --yes
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --confirm no
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --confirm yes --pre-backup no
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --confirm yes --pre-backup no --confirm-no-backup no
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --confirm yes --all
  assert_status 17
  run --separate-stderr replace_cli --container "$site" --container other.example.test --confirm yes
  assert_status 17
  refute_file_exists "$SANDBOX/decision"
  refute_command '^docker '
}

@test "replacement CLI backs up by default and accepts an explicit double confirmation to skip" {
  record_replace
  # A saved setting cannot waive the backup for a later replacement request.
  export VDM_PRE_BACKUP=false VDM_CONFIRM_NO_BACKUP=true
  run --separate-stderr replace_cli --container "$site" --confirm yes
  assert_success
  joomlaSiteJSON -e '.success and .data.site=="shop.example.test" and .data.backup==true' <<< "$output"
  assert_equal "$(head -n 1 "$SANDBOX/decision")" true

  run --separate-stderr replace_cli --container "$site" --confirm yes --pre-backup no --confirm-no-backup yes
  assert_success
  joomlaSiteJSON -e '.success and .data.backup==false' <<< "$output"
  assert_equal "$(head -n 1 "$SANDBOX/decision")" false
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

record_yes_no_dialogs() {
  whiptail() {
    local flag default=Yes
    for flag in "$@"; do [ "$flag" != --defaultno ] || default=No; done
    case " $* " in
      *" --yesno "*)
        printf '%s | %s\n' "$default" "$*" >> "$SANDBOX/yesno";;
    esac
    command whiptail "$@"
  }
}

@test "No at the data loss warning asks the backup question again with Yes selected" {
  record_replace
  record_yes_no_dialogs
  answers "$package" current "$site" yes no no yes
  run showJoomlaPlayground
  assert_success
  assert_answers_used
  assert_equal "$(head -n 1 "$SANDBOX/decision")" true
  local digest
  digest=$(joomlaPlaygroundInspectPackage "$package" json | joomlaSiteJSON -er .archiveSha256)
  assert_equal "$(tail -n 1 "$SANDBOX/decision")" "$digest"
  # The warning defaults to No. The backup prompt keeps Yes selected when
  # presented a second time. All decisions use whiptail's two-button dialog.
  local defaults
  defaults=$(awk '/^(Yes|No) \| / {print $1}' "$SANDBOX/yesno")
  assert_equal "$defaults" $'No\nYes\nNo\nYes'
  assert_file_contains "$SANDBOX/yesno" "$site"
}

@test "Yes after declining the backup accepts data loss while declining replacement does nothing" {
  record_replace
  answers "$package" current "$site" no
  run showJoomlaPlayground
  assert_success
  assert_answers_used
  refute_file_exists "$SANDBOX/decision"

  answers "$package" current "$site" yes no yes
  run showJoomlaPlayground
  assert_success
  assert_answers_used
  assert_equal "$(head -n 1 "$SANDBOX/decision")" false
  refute_command '^docker '
}

@test "replacement revalidates the previewed archive before invoking the importer" {
  OCTOJOOM_OUTPUT=json
  local wrong_digest
  printf -v wrong_digest '%064d' 0
  joomlaPlaygroundReplaceSite() { touch "$SANDBOX/import-started"; }
  run --separate-stderr joomlaPlaygroundDeployCurrent "$package" "$site" true "$wrong_digest"
  assert_failure
  joomlaSiteJSON -e '.status=="failed" and .stage=="package" and .target=="current" and
    .destructive_started==false and .running==null and .backup==null' <<< "$output"
  refute_file_exists "$SANDBOX/import-started"
  refute_command '^docker '
}

# Stub only the importer; exercise package preparation, receipt formatting
# and both entry points without changing service state.
# shellcheck disable=SC2016
record_import_result() {
  fixture_result="$1" fixture_exit="$2"
  joomlaPlaygroundReplaceSite() {
    printf '%s\n' 'private import diagnostic' >&2
    joomlaSiteJSON -nc --arg site "$2" --arg status "$fixture_result" \
      --arg backup "$SANDBOX/verified backup.tar.gz" '
      {target:"current",$site,$status,destructive_started:true,enabled:"enabled",
        stage:"database-import",reason:"Fixture import report.",running:false,$backup}' > "$1/result.json"
    return "$fixture_exit"
  }
}

# shellcheck disable=SC2016
@test "replacement CLI reports failed writes and the verified archive without exposing internal diagnostics" {
  record_import_result failed 7
  run --separate-stderr replace_cli --container "$site" --confirm yes
  assert_status 7
  joomlaSiteJSON -e --arg backup "$SANDBOX/verified backup.tar.gz" '
    .success==false and .exit_status==7 and .data.status=="failed" and .data.destructive_started and
    .data.stage=="database-import" and .data.reason=="Fixture import report." and
    .data.running==false and .data.backup==$backup and (.data.archiveSha256|length)==64' <<< "$output"
  refute_output_contains 'private import diagnostic'
}

@test "a failed import receipt cannot be presented as success when its worker returns zero" {
  record_import_result failed 0
  run --separate-stderr replace_cli --container "$site" --confirm yes
  assert_status 1
  joomlaSiteJSON -e '.success==false and .data.status=="failed"' <<< "$output"
}

@test "a successful replacement CLI preserves the public package summary" {
  record_import_result deployed 0
  run --separate-stderr replace_cli --container "$site" --confirm yes
  assert_success
  joomlaSiteJSON -e '.success and .exit_status==0 and .error==null and
    .data.status=="deployed" and .data.site=="shop.example.test" and
    (.data.archiveSha256|length)==64 and .data.databasePrefix=="demo_"' <<< "$output"
  refute_output_contains 'private import diagnostic'
}

@test "replacement menu reports an interrupted import and its verified backup" {
  record_import_result failed 130
  answers "$package" current "$site" yes yes
  run showJoomlaPlayground
  assert_status 130
  assert_answers_used
  assert_dialog 'Fixture import report.'
  assert_dialog "$SANDBOX/verified backup.tar.gz"
  refute_dialog 'private import diagnostic'
}

# Bats fills stderr when run uses --separate-stderr.
# shellcheck disable=SC2154
@test "replacement text sends failed import details to stderr" {
  record_import_result failed 1
  run --separate-stderr joomlaPlaygroundDeployCurrent "$package" "$site" true
  assert_failure
  assert_equal "$output" ''
  [[ "$stderr" == *'Fixture import report.'* && "$stderr" == *"$SANDBOX/verified backup.tar.gz"* ]]
}

@test "replacement CLI fails conservatively if the importer receipt is missing or invalid" {
  local mode
  joomlaPlaygroundReplaceSite() {
    [ "$mode" != invalid ] || printf '{' > "$1/result.json"
    return 1
  }
  for mode in missing invalid; do
    run --separate-stderr replace_cli --container "$site" --confirm yes
    assert_failure
    joomlaSiteJSON -e '.success==false and .data.status=="failed" and
      .data.running==null and .data.backup==null' <<< "$output"
  done
}

@test "replacement configuration uses the target connection and mail policy with the imported title, secret and table prefix" {
  local original="$SANDBOX/current-configuration.php" candidate="$prepared/site/configuration.php"
  cat > "$original" <<'PHP'
<?php
class JConfig {
    public $sitename = 'Old title';
    public $secret = 'private-old-key';
    public $dbtype = 'mysqli';
    public $host = 'originaldb';
    public $db = 'old_db';
    public $user = 'old_user';
    public $password = 'old-password';
    public $dbprefix = 'old_';
    public $live_site = 'https://shop.example.test';
    public $log_path = '/srv/old/logs';
    public $tmp_path = '/srv/old/tmp';
    public $smtphost = 'smtp.example.test';
    public $smtppass = 'private-old-smtp-password';
    public $custom_policy = 'retain-target-setting';
}
PHP
  cp "$original" "$SANDBOX/prior.php"
  joomlaPlaygroundPreparePackage "$package" "$prepared" >/dev/null
  parseCLI --non-interactive --site-name "Shop owner's site" --admin-password 'private-new-admin-password'
  local VDM_DB_NAME=new_db VDM_DB_USER=app_user VDM_DB_PASSWORD=private-new-db-password
  local vdm_database_name='' vdm_database_user='' vdm_database_pass=''
  joomlaPlaygroundConfirmReplaceSettings "$prepared"
  assert_equal "$vdm_database_name" new_db
  assert_equal "$vdm_database_user" app_user
  assert_equal "$vdm_database_pass" private-new-db-password

  run joomlaPlaygroundConfigureImport "$prepared" "$original" mariadbshop mysqli \
    "$vdm_database_name" "$vdm_database_user" "$vdm_database_pass" /var/www/html/public
  assert_success
  refute_output_contains private-
  cmp "$original" "$SANDBOX/prior.php"
  assert_file_contains "$candidate" 'private-fixture-key'
  refute_file_contains "$candidate" 'private-old-key'
  assert_file_contains "$candidate" 'retain-target-setting'
  assert_file_contains "$candidate" 'smtp.example.test'
  assert_file_contains "$candidate" 'private-old-smtp-password'
  assert_file_contains "$candidate" "Shop owner\\'s site"
  assert_file_contains "$candidate" 'mariadbshop'
  assert_file_contains "$candidate" 'new_db'
  assert_file_contains "$candidate" 'app_user'
  assert_file_contains "$candidate" 'private-new-db-password'
  assert_file_contains "$candidate" 'demo_'
  assert_file_contains "$candidate" '/var/www/html/public/administrator/logs'
  assert_file_contains "$candidate" '/var/www/html/public/tmp'
  refute_file_contains "$candidate" 'private-new-admin-password'
}

@test "existing-site administrator changes are applied through the private account request without editing the site environment" {
  local env_file="$VDM_REPO_PATH/joomla/.env"
  local VDM_DB_NAME=target_shop VDM_DB_USER=target_user VDM_DB_PASSWORD=private-target-password
  cp "$env_file" "$SANDBOX/original.env"
  joomlaPlaygroundPreparePackage "$package" "$prepared" >/dev/null
  parseCLI --non-interactive --admin-username shopowner --admin-password private-new-password
  joomlaPlaygroundConfirmReplaceSettings "$prepared"
  joomlaSiteJSON -e '.username=="shopowner" and .password=="private-new-password" and
    .changed.username and .changed.password' < "$prepared/account.json" >/dev/null
  if ! is_windows; then assert_equal "$(file_mode "$prepared/account.json")" 600; fi
  cmp "$env_file" "$SANDBOX/original.env"
  parseCLI --non-interactive
  joomlaPlaygroundConfirmReplaceSettings "$prepared"
  joomlaSiteJSON -e '(.changed.password|not) and (.changed.username|not)' < "$prepared/account.json" >/dev/null
  cmp "$env_file" "$SANDBOX/original.env"
}

@test "existing-site import refuses a different database identity or password" {
  joomlaPlaygroundPreparePackage "$package" "$prepared" >/dev/null
  local VDM_DB_NAME=shop_db VDM_DB_USER=shop_user VDM_DB_PASSWORD=private-existing-password
  local option value
  for option in --db-name --db-user --db-password; do
    value=changed
    parseCLI --non-interactive "$option" "$value"
    run joomlaPlaygroundConfirmReplaceSettings "$prepared"
    assert_status 17
    refute_output_contains private-existing-password
  done
  refute_command '^docker '
}
