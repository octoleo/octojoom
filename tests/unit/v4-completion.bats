#!/usr/bin/env bats
# shellcheck shell=bash
# Test globals and generated completion functions are loaded at runtime.
# shellcheck disable=SC2034,SC2154,SC1090,SC1091,SC2016
load ../helpers/common

setup() { octojoom_setup; octojoom_config; }

completion_candidates() {
  local candidate
  v4CompletionCandidates "$@" > "$SANDBOX/candidates"
  while IFS= read -r -d '' candidate; do printf '%s\n' "$candidate"; done < "$SANDBOX/candidates"
}

completion_site() {
  mkdir -p "$1/joomla/available/$2"
  printf '%s\n' 'services: {}' > "$1/joomla/available/$2/docker-compose.yml"
}

@test "Bash completion activation is sourceable and does not run operations" {
  v4Main completion bash > "$SANDBOX/completion.bash"
  bash -n "$SANDBOX/completion.bash"
  source "$SANDBOX/completion.bash"
  run complete -p octojoom
  assert_success
  [[ "$output" = *'-F _octojoom_complete octojoom'* ]]
  [ ! -s "$STUB_DIR/commands.log" ]
  [ ! -s "$STUB_DIR/dialogs.log" ]
  run v4Main completion bash --json
  assert_status 2
}

@test "completion discovers canonical groups actions and utility flags" {
  run completion_candidates 1 octojoom si
  assert_success
  [ "$output" = site ]
  run completion_candidates 1 octojoom comp
  [ "$output" = completion ]
  run completion_candidates 2 octojoom completion ''
  [ "$output" = bash ]
  run completion_candidates 2 octojoom database ''
  [ "$output" = $'export\nimport\nconsole\nswitch' ]
  run completion_candidates 2 octojoom site he
  [ "$output" = help ]
  run completion_candidates 1 octojoom --ver
  [ "$output" = --version ]
}

@test "completion offers only the selected action fields and shared globals" {
  run completion_candidates 3 octojoom site create --web
  assert_success
  [ "$output" = --webserver ]
  run completion_candidates 3 octojoom database export --web
  [ -z "$output" ]
  run completion_candidates 3 octojoom site create ''
  [[ "$output" = *--joomla-version* ]]
  [[ "$output" = *--config* ]]
  [[ "$output" != *--task* ]]
  run completion_candidates 3 octojoom completion bash ''
  [ -z "$output" ]
}

@test "completion handles separate inline and Readline-split enum values" {
  run completion_candidates 4 octojoom site create --webserver ng
  [ "$output" = nginx ]
  run completion_candidates 3 octojoom site create --webserver=ng
  [ "$output" = --webserver=nginx ]
  run completion_candidates 5 octojoom site create --webserver = ng
  [ "$output" = nginx ]
  run completion_candidates 4 octojoom site create --webserver =
  [ "$output" = $'apache\nnginx' ]
  run completion_candidates 4 octojoom site create --install f
  [ "$output" = false ]
  run completion_candidates 4 octojoom site path --target d
  [ "$output" = docroot ]
}

@test "completion honors leading options and explicit repository paths" {
  completion_site "$VDM_REPO_PATH" alpha.test
  completion_site "$SANDBOX/other repo" alternate.test
  run completion_candidates 4 octojoom site info --site al
  [ "$output" = alpha.test ]
  run completion_candidates 2 octojoom --json si
  [ "$output" = site ]
  run completion_candidates 3 octojoom --json false si
  [ "$output" = site ]
  run completion_candidates 6 octojoom --repo-path "$SANDBOX/other repo" site info --site al
  [ "$output" = alternate.test ]
  run completion_candidates 6 octojoom --repo-path = "$SANDBOX/other repo" site info --site=al
  [ "$output" = --site=alternate.test ]
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "public completion finds configured sites in a fresh home without saved paths" {
  local fresh="$SANDBOX/fresh-home"
  completion_site "$fresh/Docker" tab-demo.test
  mkdir -p "$fresh/Docker/joomla/available/tab-unconfigured.test"
  (
    unset VDM_REPO_PATH VDM_PROJECT_PATH VDM_BACKUP_PATH
    export OCTOJOOM_HOME="$fresh"
    bash "$OCTOJOOM_SCRIPT" --completion-candidates 4 octojoom site info --site tab- > "$SANDBOX/fresh-candidates"
  )
  local candidate
  local -a candidates=()
  while IFS= read -r -d '' candidate; do candidates+=("$candidate"); done < "$SANDBOX/fresh-candidates"
  [ "${#candidates[@]}" -eq 1 ]
  [ "${candidates[0]}" = tab-demo.test ]
  [ ! -e "$fresh/.config" ]
  [ ! -s "$STUB_DIR/commands.log" ]
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "completion exposes database viewer service and provider choices from schema" {
  run completion_candidates 4 octojoom service configure --service data
  [ "$output" = database-ui ]
  run completion_candidates 4 octojoom service configure --provider ''
  [ "$output" = $'adminer\nphpmyadmin' ]
  run completion_candidates 4 octojoom share start --provider ''
  [ -z "$output" ]
}

@test "completion preserves literal filesystem names and distinguishes directories" {
  local name='file $(touch SHOULD_NOT_EXIST).sql'
  mkdir -p "$SANDBOX/path space/folder"
  printf 'fixture\n' > "$SANDBOX/path space/$name"
  run completion_candidates 4 octojoom database import --input "$SANDBOX/path space/fi"
  [ "$output" = "$SANDBOX/path space/$name" ]
  run completion_candidates 3 octojoom database import "--input=$SANDBOX/path space/fi"
  [ "$output" = "--input=$SANDBOX/path space/$name" ]
  run completion_candidates 2 octojoom --repo-path "$SANDBOX/path space/f"
  [ "$output" = "$SANDBOX/path space/folder/" ]
  [ ! -e SHOULD_NOT_EXIST ]
}

@test "completion never interprets config contents or tool arguments" {
  printf '%s\n' '$(touch SHOULD_NOT_EXIST)' > "$SANDBOX/untrusted.json"
  run completion_candidates 4 octojoom --config "$SANDBOX/untrusted.json" site i
  [ "$output" = $'info\nimport' ]
  run completion_candidates 5 octojoom site exec -- echo --si
  [ -z "$output" ]
  run completion_candidates 3 octojoom site info '--=value'
  assert_success
  [ -z "$output" ]
  run completion_candidates 3 octojoom site info '--$(touch SHOULD_NOT_EXIST)=x'
  assert_success
  [ -z "$output" ]
  [ ! -e SHOULD_NOT_EXIST ]
  [ ! -s "$STUB_DIR/commands.log" ]
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "early dispatch recognizes leading option values without treating them as verbs" {
  run v4ShouldHandle --repo-path "$SANDBOX/repo" site list
  assert_success
  run v4ShouldHandle --site alpha.test site info
  assert_success
  run v4ShouldHandle --install false site create
  assert_success
  run v4ShouldHandle --repo-path site
  assert_failure
  run v4ShouldHandle --site database --type joomla --task setup
  assert_failure
  run v4ShouldHandle --type joomla --task setup
  assert_failure
  run v4ShouldHandle --completion-candidates 1 octojoom si
  assert_success
}

@test "public executable discovers completion and handles leading globals without installers" {
  run_octojoom completion bash
  assert_success
  [[ "$output" = *'_octojoom_complete()'* ]]
  run_octojoom --repo-path "$SANDBOX/unused-repo" site schema
  assert_success
  [ "$(jq -r '.actions.completion[0]' <<< "$output")" = bash ]
  [ ! -s "$STUB_DIR/dialogs.log" ]
  refute_command 'apt-get|yum|dnf|brew|choco|docker'
}

@test "generated callback retains NUL-delimited candidate and argument boundaries" {
  mkdir -p "$SANDBOX/command path"
  cat > "$SANDBOX/command path/octojoom" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$SANDBOX/completion-arguments"
printf '%s\0' 'directory with spaces/' 'literal $(touch SHOULD_NOT_EXIST)'
SH
  chmod +x "$SANDBOX/command path/octojoom"
  v4Main completion bash > "$SANDBOX/completion.bash"
  source "$SANDBOX/completion.bash"
  COMP_WORDS=("$SANDBOX/command path/octojoom" site exec --workdir 'path with spaces')
  COMP_CWORD=4
  _octojoom_complete
  [ "${#COMPREPLY[@]}" -eq 2 ]
  [ "${COMPREPLY[0]}" = 'directory with spaces/' ]
  [ "${COMPREPLY[1]}" = 'literal $(touch SHOULD_NOT_EXIST)' ]
  local argument
  local -a arguments=()
  while IFS= read -r -d '' argument; do arguments+=("$argument"); done < "$SANDBOX/completion-arguments"
  [ "${arguments[0]}" = --completion-candidates ]
  [ "${arguments[1]}" = 4 ]
  [ "${arguments[6]}" = 'path with spaces' ]
  [ ! -e SHOULD_NOT_EXIST ]
}

@test "Readline lexical dequoting preserves literal shell text without evaluation" {
  local REPLY
  _octojoom_unquote_word 'path\ space/a\\b'
  [ "$REPLY" = 'path space/a\b' ]
  _octojoom_unquote_word '"path\ space/\$literal/fi'
  [ "$REPLY" = 'path\ space/$literal/fi' ]
  _octojoom_unquote_word "'path space/fi"
  [ "$REPLY" = 'path space/fi' ]
  _octojoom_unquote_word '$(touch SHOULD_NOT_EXIST)'
  [ "$REPLY" = '$(touch SHOULD_NOT_EXIST)' ]
  [ ! -e SHOULD_NOT_EXIST ]
}

@test "generated callback completes actual escaped and quoted Readline paths" {
  local name='file $(touch SHOULD_NOT_EXIST).sql' executable escaped raw
  mkdir -p "$SANDBOX/command path" "$SANDBOX/path space"
  printf 'fixture\n' > "$SANDBOX/path space/$name"
  printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$OCTOJOOM_SCRIPT" > "$SANDBOX/command path/octojoom"
  chmod +x "$SANDBOX/command path/octojoom"
  v4Main completion bash > "$SANDBOX/completion.bash"
  source "$SANDBOX/completion.bash"
  printf -v executable '%q' "$SANDBOX/command path/octojoom"
  printf -v escaped '%q' "$SANDBOX/path space/fi"
  for raw in "$escaped" "'$SANDBOX/path space/fi" "\"$SANDBOX/path space/fi"; do
    COMP_WORDS=("$executable" database import --input "$raw")
    COMP_CWORD=4
    _octojoom_complete
    [ "${#COMPREPLY[@]}" -eq 1 ]
    [ "${COMPREPLY[0]}" = "$SANDBOX/path space/$name" ]
  done
  [ ! -e SHOULD_NOT_EXIST ]
  [ ! -s "$STUB_DIR/commands.log" ]
}
