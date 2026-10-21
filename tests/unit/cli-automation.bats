#!/usr/bin/env bats
# Each Bats test is isolated; quoted command-like inputs are intentional data.
# shellcheck disable=SC2030,SC2031,SC2034,SC2154,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
}

@test "headless: a selected lifecycle action never opens a dialog" {
  make_joomla_container alpha ALPHA alpha
  run_octojoom --container alpha.vdm.dev --non-interactive
  assert_success
  assert_file_exists "$VDM_REPO_PATH/joomla/enabled/alpha.vdm.dev"
  [ ! -s "$STUB_DIR/dialogs.log" ]
  refute_command 'apt-get|brew|choco|dnf'
}

@test "headless: missing target fails before creating an enabled directory" {
  make_joomla_container alpha ALPHA alpha
  run_octojoom --type joomla --task enable --non-interactive
  assert_status 17
  refute_file_exists "$VDM_REPO_PATH/joomla/enabled"
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "headless: incomplete fresh request does not initialize a home" {
  local fresh="$SANDBOX/fresh"
  run env OCTOJOOM_HOME="$fresh" bash "$OCTOJOOM_SCRIPT" --type openssh --task setup --non-interactive
  assert_status 17
  refute_file_exists "$fresh"
  refute_command 'docker network create'
}

@test "request values: explicit false and empty permitted text remain present after reload" {
  parseCLI --secure false --extensions= --memory-limit 512M
  cliHasValue VDM_SECURE
  cliHasValue VDM_J_EXTENSIONS_URLS
  VDM_SECURE=true VDM_J_EXTENSIONS_URLS=stale VDM_memory_limit=256M
  cliApplyValues
  assert_equal "$VDM_SECURE" false
  assert_equal "$VDM_J_EXTENSIONS_URLS" ''
  assert_equal "$VDM_memory_limit" 512M
}

@test "JSON: direct flags override requests and arguments remain literal" {
  command -v jq >/dev/null || skip 'jq is optional'
  local request="$SANDBOX/request.json"
  cat >"$request" <<'JSON'
{"type":"settings","task":"remote","options":{"secure":true,"remote":"server","extensions":""},"args":["--task","info","a b","$(touch forbidden)","雪"]}
JSON
  parseCLI --secure false --input-json "$request"
  assert_equal "$VDM_SECURE" false
  assert_equal "${OCTOJOOM_ARGS[2]}" 'a b'
  assert_equal "${OCTOJOOM_ARGS[3]}" '$(touch forbidden)'
  assert_equal "${OCTOJOOM_ARGS[4]}" '雪'
  cliHasValue VDM_J_EXTENSIONS_URLS
  refute_file_exists forbidden
}

@test "JSON: invalid schema and unknown options are rejected" {
  command -v jq >/dev/null || skip 'jq is optional'
  local request="$SANDBOX/request.json" content
  for content in '{"options":{"typo":"x"}}' '{"args":[12]}' '{"extra":true}' '{"options":{"enable":"maybe"}}' '{"options":{"domain":"bad\u0000name"}}'; do
    printf '%s' "$content" >"$request"
    run parseCLI --input-json "$request"
    assert_status 17
  done
}

@test "JSON: successful data and failure each produce one envelope" {
  command -v jq >/dev/null || skip 'jq is optional'
  run_octojoom --type settings --task paths --output json --non-interactive
  assert_success
  printf '%s' "$output" | jq -e '.success and .task == "paths" and (.data | contains("Compose:"))'
  # Bats merges stderr; inspect stdout independently for failure transport.
  run bash -c '"$1" --type joomla --task invalid --output json --non-interactive 2>"$2"' _ "$OCTOJOOM_SCRIPT" "$SANDBOX/error"
  assert_status 17
  printf '%s' "$output" | jq -e '.success == false and .exit_status == 17'
  assert_file_contains "$SANDBOX/error" 'Unsupported container type or task'
}

@test "headless: OpenSSH setup consumes literal supplied key and mount directories" {
  mkdir -p "$SANDBOX/keys/team" "$VDM_PROJECT_PATH/app"
  run_octojoom --type openssh --task setup --non-interactive --domain example.test \
    --username deploy --key deploy --port 2239 --uid 1000 --gid 1000 \
    --ssh-keys "$SANDBOX/keys/team" --mount-base "$VDM_PROJECT_PATH" --mount-dirs app
  assert_success
  assert_file_exists "$VDM_REPO_PATH/openssh/available/deploy.example.test/docker-compose.yml"
  assert_file_contains "$VDM_REPO_PATH/openssh/.env" 'PUBLIC_KEY_DIR='
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "configuration: path and read honor a site's effective private environment" {
  make_joomla_container alpha ALPHA alpha
  printf 'VDM_ALPHA_DB="private"\n' >"$VDM_REPO_PATH/joomla/available/alpha.vdm.dev/.env"
  run_octojoom --type joomla --task config --container alpha.vdm.dev --config-kind env --action read --non-interactive
  assert_success
  assert_output_contains 'private'
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "configuration: invalid replacement leaves the original untouched" {
  local before
  before=$(cat "$VDM_SRC_PATH/.env")
  printf 'bad=$(touch injected)\n' >"$SANDBOX/bad.env"
  run_octojoom --type settings --task config --action replace --file "$SANDBOX/bad.env" --non-interactive
  assert_status 17
  assert_equal "$(cat "$VDM_SRC_PATH/.env")" "$before"
  refute_file_exists injected
}

@test "domains: add and delete operate on exact domain entries" {
  run_octojoom --type domains --task add --domain example.test --non-interactive
  assert_success
  run_octojoom --type domains --task add --domain other.test --non-interactive
  assert_success
  run_octojoom --type domains --task delete --domain example.test --non-interactive
  assert_success
  assert_equal "$(cat "$VDM_SRC_PATH/.domains")" other.test
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "completion: discovery reads local names without Docker, dialogs or config writes" {
  make_joomla_container alpha ALPHA alpha
  run_octojoom --complete --container a joomla
  assert_success
  assert_equal "$output" alpha.vdm.dev
  [ ! -s "$STUB_DIR/commands.log" ]
  [ ! -s "$STUB_DIR/dialogs.log" ]
  run env OCTOJOOM_HOME="$SANDBOX/absent" bash "$OCTOJOOM_SCRIPT" --complete --task c joomla
  assert_success
  assert_output_contains clone
  refute_file_exists "$SANDBOX/absent"
}

@test "completion: installation is idempotent and a fresh Bash activates it" {
  printf '# existing shell configuration\n' >"$VDM_HOME_PATH/.bashrc"
  installShellIntegration
  installShellIntegration
  assert_equal "$(grep -c '# octojoom shell integration' "$VDM_HOME_PATH/.bashrc")" 1
  run env HOME="$VDM_HOME_PATH" bash --noprofile --rcfile "$VDM_HOME_PATH/.bashrc" -ic 'complete -p octojoom; declare -F octojoom_cd'
  assert_success
  assert_output_contains '_octojoom_complete octojoom'
  assert_output_contains 'octojoom_cd'
  removeShellIntegration
  assert_file_contains "$VDM_HOME_PATH/.bashrc" '# existing shell configuration'
  refute_file_contains "$VDM_HOME_PATH/.bashrc" '# octojoom shell integration'
  refute_file_exists "$VDM_HOME_PATH/.local/share/bash-completion/completions/octojoom"
}

@test "completion: every documented option is supplied without secret values" {
  run cliOptionNames
  assert_success
  assert_output_contains --memory-limit
  assert_output_contains --nginx-config
  assert_output_contains --remove-data
}

@test "completion: existing login precedence and symlinked bashrc remain intact" {
  printf '# user login settings\n' >"$VDM_HOME_PATH/.profile"
  printf '# user shell settings\n' >"$VDM_HOME_PATH/shell-rc"
  ln -s "$VDM_HOME_PATH/shell-rc" "$VDM_HOME_PATH/.bashrc"
  installShellIntegration
  refute_file_exists "$VDM_HOME_PATH/.bash_profile"
  [ -L "$VDM_HOME_PATH/.bashrc" ]
  assert_file_contains "$VDM_HOME_PATH/.profile" 'BASH_VERSION'
  assert_file_contains "$VDM_HOME_PATH/.profile" '# user login settings'
  removeShellIntegration
  [ -L "$VDM_HOME_PATH/.bashrc" ]
  assert_file_contains "$VDM_HOME_PATH/.bashrc" '# user shell settings'
  refute_file_contains "$VDM_HOME_PATH/.profile" '# octojoom shell integration'
}

@test "headless: explicit Cloudflare selection survives the shared question helper" {
  parseCLI --non-interactive --cloudflare true
  setSecureCloudflareState traefik
  assert_equal "$VDM_SECURE_CLOUDFLARE" true
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "headless: Traefik setup reuses a saved email without requesting it again" {
  mkdir -p "$VDM_REPO_PATH/traefik"
  printf 'VDM_SECURE_EMAIL="admin@example.test"\n' >"$VDM_REPO_PATH/traefik/.env"
  run_octojoom --type traefik --task setup --domain example.test --secure true --non-interactive
  assert_success
  assert_file_exists "$VDM_REPO_PATH/traefik/docker-compose.yml"
  [ ! -s "$STUB_DIR/dialogs.log" ]
}
