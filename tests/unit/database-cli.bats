#!/usr/bin/env bats
# Request globals and function stand-ins are consumed by the loaded application.
# shellcheck disable=SC2030,SC2031,SC2034,SC2154,SC2317,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
}

@test "database CLI retains setup aliases and literal published image references" {
  parseCLI --type joomla --task setup --db-engine postgresql --db-image registry.test:5000/postgres:chosen
  assert_equal "$VDM_DB_ENGINE" postgres
  assert_equal "$VDM_DB_IMAGE" registry.test:5000/postgres:chosen
  parseCLI --type joomla --task database --action change --container first.example.test \
    --engine mysql --database-image mysql:chosen --data-mode preserve
  assert_equal "$VDM_DB_ENGINE" mysql
  assert_equal "$VDM_DB_IMAGE" mysql:chosen
  assert_equal "$VDM_DATA_MODE" preserve
}

@test "database CLI keeps literal repeated tables and selected sites across saved-value reload" {
  parseCLI --type joomla --task database --action export --container first.example.test \
    --container second.example.test --table 'cms,archive' --table 'odd " table $literal 雪'
  assert_equal "${#VDM_SITES[@]}" 2
  assert_equal "$VDM_CONTAINER" first.example.test
  assert_equal "${VDM_SITES[1]}" second.example.test
  assert_equal "${#VDM_TABLES[@]}" 2
  assert_equal "${VDM_TABLES[0]}" 'cms,archive'
  VDM_SITES=(stale) VDM_TABLES=(stale) VDM_CONTAINER=stale
  cliApplyValues
  assert_equal "${VDM_TABLES[1]}" 'odd " table $literal 雪'
  assert_equal "${VDM_SITES[0]}" first.example.test
  cliHasValue VDM_SITES
  cliHasValue VDM_TABLES
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "database CLI preserves the existing singular container shorthand" {
  parseCLI --container first.example.test
  cliResolveTarget
  assert_equal "$VDM_CONTAINER" first.example.test
  assert_equal "$VDM_CONTAINER_TYPE" joomla
  assert_equal "$VDM_TASK" enable
  assert_equal "${#VDM_SITES[@]}" 1
}

@test "database CLI normalizes explicit negative choices and shared aliases" {
  parseCLI --type joomla --task database --action export --container first.example.test \
    --file '/private/export one.sql' --timestamp no --overwrite false --delete-source no \
    --progress no --quiet --verbose=false
  assert_equal "$VDM_FILE" '/private/export one.sql'
  assert_equal "$VDM_INPUT_FILE" "$VDM_FILE"
  assert_equal "$VDM_TIMESTAMP" false
  assert_equal "$VDM_OVERWRITE" false
  assert_equal "$VDM_DELETE_SOURCE" false
  assert_equal "$VDM_PROGRESS" false
  assert_equal "$OCTOJOOM_NO_PROGRESS" true
  assert_equal "$VDM_QUIET" true
  assert_equal "$VDM_VERBOSE" false
  VDM_TIMESTAMP=true VDM_FILE=stale VDM_PROGRESS=true VDM_QUIET=false
  cliApplyValues
  assert_equal "$VDM_TIMESTAMP" false
  assert_equal "$VDM_FILE" '/private/export one.sql'
  assert_equal "$VDM_PROGRESS" false
  assert_equal "$VDM_QUIET" true
  cliHasValue VDM_FILE
}

@test "JSON database arrays preserve boundaries and direct options replace whole selections" {
  command -v jq >/dev/null || skip 'JSON transport needs jq'
  local request="$SANDBOX/request.json"
  cat >"$request" <<'JSON'
{"type":"joomla","task":"database","action":"export","container":["json.example.test","other.example.test"],"options":{"table":["cms,archive","odd table 雪"],"timestamp":true,"overwrite":true,"destination":"/saved folder"}}
JSON
  parseCLI --input-json "$request" --container flag.example.test --container next.example.test \
    --table 'one,two' --table '$literal' --timestamp no --overwrite no
  assert_equal "${VDM_SITES[*]}" 'flag.example.test next.example.test'
  assert_equal "${#VDM_TABLES[@]}" 2
  assert_equal "${VDM_TABLES[0]}" 'one,two'
  assert_equal "${VDM_TABLES[1]}" '$literal'
  assert_equal "$VDM_TIMESTAMP" false
  assert_equal "$VDM_OVERWRITE" false
  assert_equal "$VDM_DESTINATION" '/saved folder'
  VDM_TABLES=(stale) VDM_SITES=(stale)
  cliApplyValues
  assert_equal "${VDM_SITES[*]}" 'flag.example.test next.example.test'
  assert_equal "${VDM_TABLES[1]}" '$literal'
}

@test "JSON selections accept arrays only for container and table and reject empty selection" {
  command -v jq >/dev/null || skip 'JSON transport needs jq'
  local request="$SANDBOX/request.json" content
  for content in '{"container":[]}' '{"container":["ok.test",12]}' '{"options":{"table":[]}}' \
    '{"options":{"table":[""]}}' '{"options":{"table":["bad\u0000name"]}}' \
    '{"options":{"file":["one","two"]}}' '{"action":"bad\u0000action"}'; do
    printf '%s' "$content" >"$request"
    run parseCLI --input-json "$request"
    assert_status 17
  done
}

@test "JSON credentials stay out of child argument lists and diagnostics" {
  command -v jq >/dev/null || skip 'JSON transport needs jq'
  local request="$SANDBOX/private.json"
  printf '%s\n' '{"type":"joomla","task":"setup","options":{"db-password":"private secret $dollar `literal`"}}' >"$request"
  jq() { printf '%s\n' "$@" >>"$STUB_DIR/jq-arguments"; command jq "$@"; }
  run parseCLI --input-json "$request"
  assert_success
  refute_output_contains 'private secret'
  refute_file_contains "$STUB_DIR/jq-arguments" 'private secret'
}

@test "database CLI rejects ambiguous batch and incompatible logging choices without writes" {
  run parseCLI --type joomla --task database --action export --all --container first.example.test
  assert_status 17
  run parseCLI --type joomla --task backup --action create --container first.example.test --container second.example.test --file same.tar.gz
  assert_status 17
  run parseCLI --type joomla --task database --action import --container first.example.test --container second.example.test
  assert_status 17
  run parseCLI --type joomla --task database --action export --quiet --verbose
  assert_status 17
  [ ! -s "$STUB_DIR/commands.log" ]
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "database CLI rejects unsupported options values without exposing supplied data" {
  local argument
  for argument in --engine=other --data-mode=implicit --compression=unknown --format=rar --scope=everything \
    --target=any --import-mode=guess --retention=-1 --timestamp=maybe; do
    run parseCLI --type joomla --task database --action export "$argument"
    assert_status 17
  done
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "database import preflight requires a target file and explicit import semantics" {
  parseCLI --type joomla --task database --action import --container first.example.test --file "$SANDBOX/import.sql"
  run cliDataPreflight
  assert_status 17
  assert_output_contains '--import-mode'
  VDM_IMPORT_MODE=fresh
  run cliDataPreflight
  assert_status 17
  cliRememberValue VDM_IMPORT_MODE fresh
  run cliDataPreflight
  assert_success
  VDM_INPUT_FILE='' VDM_FILE=''
  run cliDataPreflight
  assert_status 17
  [ ! -s "$STUB_DIR/dialogs.log" ]
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "database change requires explicit intent and confirmation before any work" {
  parseCLI --type joomla --task database --action change --container first.example.test \
    --engine mysql --database-image mysql:chosen --data-mode preserve
  VDM_CONFIRM=true
  run cliDataPreflight
  assert_status 17
  assert_output_contains '--confirm yes'
  cliRememberValue VDM_CONFIRM true
  run cliDataPreflight
  assert_success
  run cliTaskNames joomla
  assert_output_contains database
  refute_output_contains database_change
  [ ! -s "$STUB_DIR/dialogs.log" ]
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "backup deletion and current-site restore require explicit destructive choices" {
  parseCLI --type joomla --task backup --action cleanup --container first.example.test --retention 2
  VDM_CONFIRM=true
  run cliDataPreflight
  assert_status 17
  cliRememberValue VDM_CONFIRM true
  run cliDataPreflight
  assert_success
  parseCLI --type joomla --task backup --action restore --container first.example.test \
    --target current --file "$SANDBOX/saved.tar.gz" --confirm yes
  VDM_PRE_BACKUP=true
  run cliDataPreflight
  assert_status 17
  cliRememberValue VDM_PRE_BACKUP true
  run cliDataPreflight
  assert_success
  [ ! -s "$STUB_DIR/dialogs.log" ]
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "SQL consoles never enter headless or JSON transport" {
  parseCLI --type joomla --task database --action console --container first.example.test --non-interactive
  run cliDataPreflight
  assert_status 17
  assert_output_contains 'interactive terminal'
  run parseCLI --type joomla --task database --action console --container first.example.test --output json
  assert_status 17
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "backup verification and new-site restore do not require a surviving source site" {
  parseCLI --type joomla --task backup --action verify --file "$SANDBOX/saved.tar.gz"
  run cliDataPreflight
  assert_success
  parseCLI --type joomla --task backup --action restore --file "$SANDBOX/saved.tar.gz" \
    --target new --key review --domain example.test --sub-domain review
  run cliDataPreflight
  assert_success
  VDM_TARGET=current
  run cliDataPreflight
  assert_status 17
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "backup CLI keeps explicit confirmation and retention zero after a reload" {
  parseCLI --type joomla --task backup --action create --all --scope full --format zip \
    --destination '/backups/team one' --label 'before change' --retention 0 \
    --timestamp no --overwrite no --pre-backup yes --confirm yes
  VDM_RETENTION=10 VDM_TIMESTAMP=true VDM_PRE_BACKUP=false VDM_CONFIRM=false
  cliApplyValues
  assert_equal "$VDM_RETENTION" 0
  assert_equal "$VDM_TIMESTAMP" false
  assert_equal "$VDM_PRE_BACKUP" true
  assert_equal "$VDM_CONFIRM" true
  assert_equal "$VDM_LABEL" 'before change'
  run cliDataPreflight
  assert_success
}

@test "batch JSON output remains one envelope on partial failure with stderr diagnostics" {
  command -v jq >/dev/null || skip 'JSON transport needs jq'
  parseCLI --type joomla --task database --action export --container first.example.test \
    --container second.example.test --output json --quiet
  main() {
    printf 'Second site export failed.\n' >&2
    printf '%s\n' '[{"site":"first.example.test","success":true,"file":"/saved.sql"},{"site":"second.example.test","success":false}]'
    return 7
  }
  local code=0
  cliExecute >"$SANDBOX/result.json" 2>"$SANDBOX/error" || code=$?
  assert_equal "$code" 7
  jq -e '.success == false and .exit_status == 7 and (.data | length == 2) and .data[0].success and (.data[1].success | not)' "$SANDBOX/result.json"
  assert_file_contains "$SANDBOX/error" 'Second site export failed'
}

@test "completion suggests database and backup choices without accessing live services" {
  run cliComplete --action '' joomla database
  assert_success
  assert_output_contains export
  assert_output_contains console
  refute_output_contains cleanup
  run cliComplete --action '' joomla backup
  assert_success
  assert_output_contains restore
  assert_output_contains cleanup
  run cliComplete --engine p joomla database
  assert_equal "$output" postgres
  run cliComplete --scope '' joomla backup
  assert_output_contains website
  run cliComplete --table '' joomla database
  assert_equal "$output" ''
  [ ! -s "$STUB_DIR/commands.log" ]
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "completion preserves local backup paths containing spaces and passes the selected task" {
  mkdir -p "$SANDBOX/backup files" "$SANDBOX/bin"
  touch "$SANDBOX/backup files/before change.tar.gz"
  run cliComplete --file "$SANDBOX/backup files/b" joomla backup
  assert_equal "$output" "$SANDBOX/backup files/before change.tar.gz"
  cliCompletionScript >"$SANDBOX/completion"
  cat >"$SANDBOX/bin/octojoom" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_DIR/completion-args"
printf 'export\n'
SH
  chmod +x "$SANDBOX/bin/octojoom"
  PATH="$SANDBOX/bin:$PATH"
  # shellcheck disable=SC1091
  source "$SANDBOX/completion"
  COMP_WORDS=(octojoom --type joomla --task "=" database --action e)
  COMP_CWORD=7
  _octojoom_complete
  assert_equal "${COMPREPLY[0]}" export
  assert_equal "$(tail -n 1 "$STUB_DIR/completion-args")" database
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "backup options follow each selected site and explicit negative choices override saved defaults" {
  make_joomla_container alpha ALPHA first
  make_joomla_container beta BETA second
  writeEnvVariable "$VDM_REPO_PATH/joomla/.env" "VDM_ALPHA_BACKUP_PATH=$SANDBOX/first backups" true
  writeEnvVariable "$VDM_REPO_PATH/joomla/.env" 'VDM_ALPHA_BACKUP_FORMAT=zip' true
  writeEnvVariable "$VDM_REPO_PATH/joomla/.env" "VDM_BETA_BACKUP_PATH=$SANDBOX/second backups" true
  writeEnvVariable "$VDM_REPO_PATH/joomla/.env" 'VDM_BETA_BACKUP_FORMAT=tar.gz' true
  writeEnvVariable "$VDM_REPO_PATH/joomla/.env" 'VDM_BETA_BACKUP_OVERWRITE=true' true
  OCTOJOOM_CLI_KEYS=()
  VDM_DESTINATION=stale VDM_FORMAT=invalid VDM_TIMESTAMP=stale
  joomlaBackupResolveOptions first.vdm.dev
  assert_equal "$VDM_DESTINATION" "$SANDBOX/first backups"
  assert_equal "$VDM_FORMAT" zip
  joomlaBackupResolveOptions second.vdm.dev
  assert_equal "$VDM_DESTINATION" "$SANDBOX/second backups"
  assert_equal "$VDM_FORMAT" tar.gz
  assert_equal "$VDM_OVERWRITE" true
  parseCLI --type joomla --task backup --action create --container second.vdm.dev \
    --destination "$SANDBOX/explicit" --format zip --scope files --timestamp no --overwrite no --retention 0
  joomlaBackupResolveOptions second.vdm.dev
  assert_equal "$VDM_DESTINATION" "$SANDBOX/explicit"
  assert_equal "$VDM_FORMAT" zip
  assert_equal "$VDM_SCOPE" files
  assert_equal "$VDM_TIMESTAMP" false
  assert_equal "$VDM_OVERWRITE" false
  assert_equal "$VDM_RETENTION" 0
}

@test "backup batch JSON does not reuse a successful archive in a later failed site result" {
  command -v jq >/dev/null || skip 'JSON transport needs jq'
  make_joomla_container alpha ALPHA first
  parseCLI --type joomla --task backup --action create --container first.vdm.dev \
    --container missing.vdm.dev --destination "$SANDBOX/backups" --timestamp no --output json --non-interactive
  joomlaBackupCreate() { printf '%s\n' "$2" >> "$STUB_DIR/created-backups"; }
  migrationArchiveDigest() { printf 'verified-digest\n'; }
  main() { joomla__TRuST__backup; }
  local code=0
  cliExecute > "$SANDBOX/result.json" 2> "$SANDBOX/error" || code=$?
  [ "$code" -ne 0 ]
  jq -e '.success == false and (.data|length)==2 and .data[0].exit_status==0 and
    (.data[0].archive|endswith("first.vdm.dev-full.tar.gz")) and
    .data[1].site=="missing.vdm.dev" and .data[1].exit_status!=0 and
    .data[1].archive=="" and .data[1].digest=="" and .data[1].scope==""' "$SANDBOX/result.json"
  assert_equal "$(wc -l < "$STUB_DIR/created-backups" | tr -d ' ')" 1
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "interactive backup batch gathers shared answers once while complete CLI requests stay prompt-free" {
  make_joomla_container alpha ALPHA first
  make_joomla_container beta BETA second
  VDM_ACTION=create VDM_CONTAINER=first.vdm.dev OCTOJOOM_NON_INTERACTIVE=false
  VDM_SITES=(first.vdm.dev second.vdm.dev)
  OCTOJOOM_CLI_KEYS=()
  joomlaBackupCreateQuestions() {
    printf 'questions\n' >> "$STUB_DIR/backup-questions"
    VDM_DESTINATION="$SANDBOX/common" VDM_FORMAT=zip VDM_SCOPE=files
    VDM_TIMESTAMP=false VDM_OVERWRITE=false VDM_RETENTION=0
  }
  joomlaBackupCreate() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$STUB_DIR/created-backups"; }
  migrationArchiveDigest() { printf 'verified-digest\n'; }
  joomla__TRuST__backup > /dev/null
  assert_equal "$(wc -l < "$STUB_DIR/backup-questions" | tr -d ' ')" 1
  assert_file_contains "$STUB_DIR/created-backups" "first.vdm.dev|$SANDBOX/common/first.vdm.dev-files.zip|files"
  assert_file_contains "$STUB_DIR/created-backups" "second.vdm.dev|$SANDBOX/common/second.vdm.dev-files.zip|files"
  parseCLI --type joomla --task backup --action create --container first.vdm.dev \
    --destination "$SANDBOX/cli" --format tar.gz --scope database --timestamp no
  joomla__TRuST__backup > /dev/null
  assert_equal "$(wc -l < "$STUB_DIR/backup-questions" | tr -d ' ')" 1
  assert_file_contains "$STUB_DIR/created-backups" "first.vdm.dev|$SANDBOX/cli/first.vdm.dev-database.tar.gz|database"
}

@test "backup menu create does not reuse the archive from a previous verification" {
  make_joomla_container alpha ALPHA first
  OCTOJOOM_CLI_KEYS=()
  joomlaBackupList() { :; }
  joomlaBackupVerify() { printf 'Verified archive\n'; }
  joomlaBackupCreateQuestions() {
    VDM_DESTINATION="$SANDBOX/backups" VDM_FORMAT=tar.gz VDM_SCOPE=full
    VDM_TIMESTAMP=false VDM_OVERWRITE=true VDM_RETENTION=0
  }
  joomlaBackupCreate() { printf '%s\n' "$2" > "$STUB_DIR/created-backups"; }
  migrationArchiveDigest() { printf 'verified-digest\n'; }
  answers verify manual "$SANDBOX/old-restore-point.tar.gz" create back
  showJoomlaBackups first.vdm.dev
  assert_answers_used
  assert_equal "$(cat "$STUB_DIR/created-backups")" "$SANDBOX/backups/first.vdm.dev-full.tar.gz"
}
