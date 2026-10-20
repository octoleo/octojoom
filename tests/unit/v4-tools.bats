#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2317,SC2154
load ../helpers/common
bats_require_minimum_version 1.5.0

setup() {
  octojoom_setup
  V4_REQUEST='{}'
  V4_ARGS=()
  V4_RESULT_FILE=''
  V4_ERROR_FILE=''
  v4ToolsFixture abc 5.4.9
}

v4ToolsFixture() {
  local key="$1" version="$2" directory="$VDM_REPO_PATH/joomla/available/$1.test" project="$VDM_PROJECT_PATH/$1"
  mkdir -p "$directory" "$project/joomla/administrator/manifests/files" "$project/db"
  printf 'services: {}\n' > "$directory/docker-compose.yml"
  printf 'VDM_PROJECT_PATH="%s"\nVDM_%s_DB_PASS="unprinted-secret"\n' "$VDM_PROJECT_PATH" "${key^^}" > "$directory/.env"
  printf '<extension><version>%s</version></extension>\n' "$version" > "$project/joomla/administrator/manifests/files/joomla.xml"
  printf "<?php\nclass JConfig {\n public \$sitename = 'Test website';\n}\n" > "$project/joomla/configuration.php"
  jq -nc --arg host "$key.test" --arg key "$key" --arg env "${key^^}" --arg root "$project" --arg version "$version" \
    '{schema_version:1,host:$host,key:$key,env_key:$env,project_dir:$root,docroot:"joomla",image:"joomla:5.4.9-php8.3-apache",joomla_version:$version,php_version:"8.3",webserver:"apache",profile:"local",http_port:8080,database:{engine:"mariadb",version:"11.4",name:"joomla",user:"joomla"},tls:{mode:"none",resolver:"vdmresolver"},services:{mail:false,redis:false,node:false},hooks:{}}' > "$directory/project.json"
  V4_REQUEST=$(jq -nc --arg site "$key.test" '{site:$site}')
}

v4Stopped() {
  v4ContainerState() { printf '{"status":"exited","running":false,"health":null}\n'; }
  v4Compose() { return 0; }
}

@test "v4 tools: info reads installed Joomla version and excludes scoped credentials" {
  v4Stopped
  run v4SiteInfo
  assert_success
  [ "$(jq -r .joomla_version <<< "$output")" = 5.4.9 ]
  [ "$(jq -r .host <<< "$output")" = abc.test ]
  [ "$(jq -r .status <<< "$output")" = exited ]
  [[ "$output" != *unprinted-secret* ]]
  [[ "$output" != *DB_PASS* ]]
}

@test "v4 tools: actual runtime PHP and server database versions are reported" {
  v4ContainerState() { printf '{"status":"running","running":true,"health":"healthy"}\n'; }
  v4Compose() { return 0; }
  v4Exec() { case "$1" in joomla*) printf 8.3.14 ;; *) printf 11.4.5-MariaDB ;; esac; }
  run v4SiteInfo
  assert_success
  [ "$(jq -r .php_version <<< "$output")" = 8.3.14 ]
  [ "$(jq -r .database.version <<< "$output")" = 11.4.5-MariaDB ]
}

@test "v4 tools: inventory filters installed release independently of image metadata" {
  v4ToolsFixture xyz 6.1.4
  v4Stopped
  V4_REQUEST='{"filter":"5.4","state":"stopped"}'
  run v4SiteList
  assert_success
  [ "$(jq '.sites|length' <<< "$output")" -eq 1 ]
  [ "$(jq -r '.sites[0].host' <<< "$output")" = abc.test ]
}

@test "v4 tools: inventory rejects invalid filter before inspecting containers" {
  V4_REQUEST='{"filter":"$(touch /tmp/no)"}'
  run v4SiteList
  assert_status 2
}

@test "v4 tools: local site URL reflects allocated port" {
  v4LoadSite abc.test
  v4Compose() { [ "$1" != port ] || printf '127.0.0.1:49152\n'; }
  run v4SiteUrls
  assert_success
  [ "$(jq -r .site <<< "$output")" = http://abc.test:49152 ]
  [ "$(jq -r .admin <<< "$output")" = http://abc.test:49152/administrator ]
}

@test "v4 tools: PostgreSQL database UI uses Adminer port 8080" {
  v4LoadSite abc.test
  V4_DB_ENGINE=postgres
  v4Compose() {
    if [ "$1" = port ] && [ "$2" = adminerabc ] && [ "$3" = 8080 ]; then printf '127.0.0.1:49153\n'; fi
  }
  run v4SiteUrls
  assert_success
  [ "$(jq -r .database <<< "$output")" = http://127.0.0.1:49153 ]
}

@test "v4 tools: legacy mail resolves to Mailcatcher" {
  v4LoadSite abc.test
  rm "$V4_DIR/project.json"
  printf 'mailcatcherabc:\n' > "$V4_COMPOSE"
  V4_META=$(jq '.services.mail=true' <<< "$V4_META")
  run v4ServiceName mail
  assert_success
  [ "$output" = mailcatcherabc ]
}

@test "v4 tools: path returns selected project directory without shell change" {
  V4_REQUEST='{"site":"abc.test","target":"project"}'
  run v4SitePath
  assert_success
  [ "$(jq -r .path <<< "$output")" = "$VDM_PROJECT_PATH/abc" ]
}

@test "v4 tools: permissions require explicit confirmation before changing files" {
  run v4SitePermissions
  assert_status 2
  refute_command '^docker '
}

@test "v4 tools: permissions reject a symlinked configuration file" {
  V4_REQUEST='{"site":"abc.test","yes":true}'
  mv "$VDM_PROJECT_PATH/abc/joomla/configuration.php" "$SANDBOX/configuration.php"
  ln -s "$SANDBOX/configuration.php" "$VDM_PROJECT_PATH/abc/joomla/configuration.php"
  run v4SitePermissions
  assert_status 2
  refute_command '^docker '
}

@test "v4 tools: permissions reject an override pointing outside the managed document root" {
  V4_REQUEST='{"site":"abc.test","yes":true}'
  v4Compose() { printf '{"services":{"joomlaabc":{"volumes":[{"type":"bind","source":"/other/site","target":"/var/www/html"}]}}}\n'; }
  v4Quiesce() { printf quiesced > "$STUB_DIR/permissions-state"; }
  run v4SitePermissions
  assert_status 2
  [ ! -e "$STUB_DIR/permissions-state" ]
}

@test "v4 tools: permissions use runtime ownership and physical traversal then restore service state" {
  V4_REQUEST='{"site":"abc.test","yes":true}'
  v4Compose() {
    if [ "$1" = config ]; then jq -nc --arg source "$V4_DOCROOT" '{services:{joomlaabc:{volumes:[{type:"bind",source:$source,target:"/var/www/html"}]}}}'; return; fi
    printf '%s\n' "${@: -1}" > "$STUB_DIR/permissions-script"
    printf '{"directories":8,"files":12,"symlinks_skipped":1,"configuration_private":true,"uid":33,"gid":33}\n'
  }
  v4Quiesce() { V4_RESUME_SERVICES=(joomlaabc); printf quiesced > "$STUB_DIR/permissions-state"; }
  v4Resume() { printf resumed >> "$STUB_DIR/permissions-state"; }
  v4WaitServices() { [ "$*" = '120 joomlaabc' ]; }
  run v4SitePermissions
  assert_success
  [ "$(jq -r .configuration_mode <<< "$output")" = 0600 ]
  [ "$(jq .files <<< "$output")" -eq 12 ]
  [ "$(cat "$STUB_DIR/permissions-state")" = quiescedresumed ]
  grep -q 'find -P' "$STUB_DIR/permissions-script"
  grep -q 'id -u www-data' "$STUB_DIR/permissions-script"
  [ ! -d "$VDM_REPO_PATH/joomla/available/abc.test/.operation.lock" ]
}

@test "v4 tools: failed permissions repair restores services and returns failure" {
  V4_REQUEST='{"site":"abc.test","yes":true}'
  v4Compose() {
    if [ "$1" = config ]; then jq -nc --arg source "$V4_DOCROOT" '{services:{joomlaabc:{volumes:[{type:"bind",source:$source,target:"/var/www/html"}]}}}'; else return 17; fi
  }
  v4Quiesce() { V4_RESUME_SERVICES=(joomlaabc); }
  v4Resume() { printf resumed > "$STUB_DIR/permissions-state"; }
  v4WaitServices() { return 0; }
  run v4SitePermissions
  assert_failure
  [ "$(cat "$STUB_DIR/permissions-state")" = resumed ]
  [ ! -d "$VDM_REPO_PATH/joomla/available/abc.test/.operation.lock" ]
}

@test "v4 tools: open print returns resource without launching browser" {
  V4_REQUEST='{"site":"abc.test","target":"directory","print":true}'
  v4OpenResource() { return 99; }
  run v4SiteOpen
  assert_success
  [ "$(jq -r .resource <<< "$output")" = "$VDM_PROJECT_PATH/abc/joomla" ]
}

@test "v4 tools: temporary stop retains enabled-site link" {
  mkdir -p "$VDM_REPO_PATH/joomla/enabled"
  ln -s "$VDM_REPO_PATH/joomla/available/abc.test" "$VDM_REPO_PATH/joomla/enabled/abc.test"
  v4Compose() { printf '%s\n' "$*" >> "$STUB_DIR/lifecycle"; }
  run v4SiteStop
  assert_success
  [ -L "$VDM_REPO_PATH/joomla/enabled/abc.test" ]
  grep -qx 'stop --timeout 120' "$STUB_DIR/lifecycle"
}

@test "v4 tools: explicit disable removes enabled-site link after stopping" {
  mkdir -p "$VDM_REPO_PATH/joomla/enabled"
  ln -s "$VDM_REPO_PATH/joomla/available/abc.test" "$VDM_REPO_PATH/joomla/enabled/abc.test"
  V4_REQUEST='{"site":"abc.test","disable":true}'
  v4Compose() { return 0; }
  run v4SiteStop
  assert_success
  [ ! -L "$VDM_REPO_PATH/joomla/enabled/abc.test" ]
}

@test "v4 tools: failed stop preserves enabled-site link and returns failure" {
  mkdir -p "$VDM_REPO_PATH/joomla/enabled"
  ln -s "$VDM_REPO_PATH/joomla/available/abc.test" "$VDM_REPO_PATH/joomla/enabled/abc.test"
  V4_REQUEST='{"site":"abc.test","disable":true}'
  v4Compose() { return 42; }
  run v4SiteStop
  assert_status 42
  [ -L "$VDM_REPO_PATH/joomla/enabled/abc.test" ]
  [ ! -d "$VDM_REPO_PATH/joomla/available/abc.test/.operation.lock" ]
}

@test "v4 tools: start publishes enabled state only after readiness" {
  v4Compose() { return 0; }
  v4WaitReady() { return 1; }
  run v4SiteStart
  assert_failure
  [ ! -L "$VDM_REPO_PATH/joomla/enabled/abc.test" ]
}

@test "v4 tools: nginx readiness checks the HTTP frontend too" {
  v4LoadSite abc.test
  V4_META=$(jq '.webserver="nginx"' <<< "$V4_META")
  v4ContainerState() {
    if [[ "$1" == nginx* ]]; then printf '{"status":"exited","running":false,"health":null}\n'; else printf '{"status":"running","running":true,"health":"healthy"}\n'; fi
  }
  run v4WaitReady 1
  assert_failure
  [[ "$output" == *nginxabc* ]]
}

@test "v4 tools: enabled companions must become healthy" {
  v4LoadSite abc.test
  V4_META=$(jq '.services.redis=true' <<< "$V4_META")
  v4ContainerState() {
    if [[ "$1" == redis* ]]; then printf '{"status":"running","running":true,"health":"unhealthy"}\n'; else printf '{"status":"running","running":true,"health":"healthy"}\n'; fi
  }
  run v4WaitReady 1
  assert_failure
  [[ "$output" == *redisabc* ]]
}

@test "v4 tools: batch operations retain successful and failed per-site results" {
  v4ToolsFixture xyz 6.1.4
  V4_REQUEST='{"all":true}'
  v4TestAction() {
    v4Result "$(jq -nc --arg site "$(v4Get site)" '{site:$site}')"
    [ "$(v4Get site)" != xyz.test ]
  }
  V4_RESULT_FILE="$STUB_DIR/batch.json"
  run v4ToolsBatch v4TestAction
  assert_failure
  [ "$(jq .succeeded "$STUB_DIR/batch.json")" -eq 1 ]
  [ "$(jq .failed "$STUB_DIR/batch.json")" -eq 1 ]
  [ "$(jq -r '.results[1].error' "$STUB_DIR/batch.json")" = 'The site operation exited with status 1.' ]
}

@test "v4 tools: delete requires explicit confirmation" {
  run v4SiteDelete
  assert_status 2
  [ -f "$VDM_REPO_PATH/joomla/available/abc.test/.env" ]
}

@test "v4 tools: delete retains recoverable scoped configuration outside webroot" {
  V4_REQUEST='{"site":"abc.test","yes":true}'
  v4Compose() { return 0; }
  v4ShareRemove() { return 0; }
  v4LocalRemoveSite() { return 0; }
  run v4SiteDelete
  assert_success
  [ ! -d "$VDM_REPO_PATH/joomla/available/abc.test" ]
  [ -d "$VDM_PROJECT_PATH/abc/joomla" ]
  local recovery
  recovery=$(jq -r .recovery_directory <<< "$output")
  [[ "$recovery" == "$VDM_SRC_PATH/recovery/"* ]]
  [ -f "$recovery/.env" ]
}

@test "v4 tools: legacy deletion retains only referenced shared environment values" {
  v4ToolsLoad() {
    v4LoadSite abc.test || return $?
    V4_ENV_FILE="$VDM_SRC_PATH/.env"
  }
  printf 'services:\n  web:\n    environment:\n      PASSWORD: ${VDM_ABC_DB_PASS}\n' > "$VDM_REPO_PATH/joomla/available/abc.test/docker-compose.yml"
  printf 'VDM_ABC_DB_PASS="retained-value"\nVDM_OTHER_DB_PASS="unrelated-secret"\n' > "$VDM_SRC_PATH/.env"
  V4_REQUEST='{"site":"abc.test","yes":true}'
  v4Compose() { return 0; }
  v4ShareRemove() { return 0; }
  v4LocalRemoveSite() { return 0; }
  run v4SiteDelete
  assert_success
  local recovery
  recovery=$(jq -r .recovery_directory <<< "$output")
  grep -q retained-value "$recovery/.env"
  run ! grep -q unrelated-secret "$recovery/.env"
}

@test "v4 tools: explicit managed data deletion removes both project and configuration" {
  V4_REQUEST='{"site":"abc.test","yes":true,"delete_data":true}'
  v4Compose() { return 0; }
  v4ShareRemove() { return 0; }
  v4LocalRemoveSite() { return 0; }
  run v4SiteDelete
  assert_success
  [ "$(jq .data_deleted <<< "$output")" = true ]
  [ ! -d "$VDM_PROJECT_PATH/abc" ]
  [ ! -d "$VDM_REPO_PATH/joomla/available/abc.test" ]
}

@test "v4 tools: arbitrary command arguments retain spaces and shell syntax literally" {
  V4_ARGS=(printf '%s' 'a space; $(touch unsafe)')
  v4Compose() { jq -nc '$ARGS.positional' --args -- "$@"; }
  run v4SiteExec
  assert_success
  [ "$(jq -r '.stdout|fromjson|last' <<< "$output")" = 'a space; $(touch unsafe)' ]
}

@test "v4 tools: command exit status and diagnostics survive structured output" {
  v4TestCommand() { printf 'normal output'; printf 'diagnostic' >&2; return 17; }
  run v4ToolRun v4TestCommand
  assert_status 17
  [ "$(jq -r .stdout <<< "$output")" = 'normal output' ]
  [ "$(jq -r .stderr <<< "$output")" = diagnostic ]
  [ "$(jq .exit_code <<< "$output")" -eq 17 ]
}

@test "v4 tools: interactive shell rejects JSON before execution" {
  V4_REQUEST='{"site":"abc.test","json":true}'
  run v4SiteShell
  assert_status 2
}

@test "v4 tools: following logs rejects structured JSON mode" {
  V4_REQUEST='{"site":"abc.test","follow":true,"json":true}'
  run v4SiteLogs
  assert_status 2
}

@test "v4 tools: configure hooks persists explicit argument arrays" {
  V4_REQUEST='{"site":"abc.test","event":"post-import-db","commands":[["php","cli/joomla.php","cache:clean"]]}'
  run v4HookConfigure
  assert_success
  [ "$(jq -r '.hooks["post-import-db"][0][2]' "$VDM_REPO_PATH/joomla/available/abc.test/project.json")" = cache:clean ]
}

@test "v4 tools: shared hooks validator permits explicit supported events only" {
  run v4ValidateHooks '{"pre-import":[["php","check.php"]],"post-restore":[]}'
  assert_success
  run v4ValidateHooks '{"post-unknown":[["php","check.php"]]}'
  assert_status 2
}

@test "v4 tools: shared hooks validator rejects shell strings and empty executable" {
  run v4ValidateHooks '{"post-start":"php cli/joomla.php"}'
  assert_status 2
  run v4ValidateHooks '{"post-start":[["","argument"]]}'
  assert_status 2
}

@test "v4 tools: shared hooks validator rejects control characters" {
  run v4ValidateHooks '{"post-start":[["printf","line\nline"]]}'
  assert_status 2
}

@test "v4 tools: hooks execute arrays without interpreting shell text" {
  v4LoadSite abc.test
  V4_META=$(jq '.hooks["post-start"]=[["printf","%s","a b; $(touch unsafe)"]]' <<< "$V4_META")
  v4HookExec() { jq -nc '$ARGS.positional' --args -- "$@" > "$STUB_DIR/hook-argv"; }
  run v4RunHook post-start
  assert_success
  [ "$(jq -r '.[2]' "$STUB_DIR/hook-argv")" = 'a b; $(touch unsafe)' ]
}

@test "v4 tools: hook argv permits and preserves an empty argument" {
  V4_REQUEST='{"site":"abc.test","event":"post-start","commands":[["printf","%s",""]]}'
  run v4HookConfigure
  assert_success
  v4LoadSite abc.test
  v4HookExec() { jq -nc '$ARGS.positional' --args -- "$@" > "$STUB_DIR/hook-argv"; }
  run v4RunHook post-start
  assert_success
  [ "$(jq length "$STUB_DIR/hook-argv")" -eq 3 ]
  [ "$(jq -r '.[2]' "$STUB_DIR/hook-argv")" = '' ]
}

@test "v4 tools: failed hooks prevent following commands" {
  v4LoadSite abc.test
  V4_META=$(jq '.hooks["post-start"]=[["first"],["second"]]' <<< "$V4_META")
  v4HookExec() { printf '%s\n' "$1" >> "$STUB_DIR/hooks-called"; return 7; }
  run v4RunHook post-start
  assert_failure
  [ "$(cat "$STUB_DIR/hooks-called")" = first ]
}

@test "v4 tools: pre-start hooks use one-shot command entrypoint without installer" {
  v4LoadSite abc.test
  v4ContainerState() { printf '{"status":"missing","running":false,"health":null}\n'; }
  v4Compose() { jq -nc '$ARGS.positional' --args -- "$@"; }
  run v4HookExec php script.php
  assert_success
  [ "$(jq -r '.[0]' <<< "$output")" = run ]
  [[ "$output" == *'"--entrypoint","php","joomlaabc","script.php"'* ]]
}

@test "v4 tools: cached Composer integrity failure refuses execution" {
  v4LoadSite abc.test
  mkdir -p "$V4_DIR/tools"
  printf corrupt > "$V4_DIR/tools/composer-2.10.3.phar"
  run v4ComposerPhar 2.10.3
  assert_failure
  [[ "$output" == *integrity* ]]
}

@test "v4 tools: Composer fallback uses the selected PHP image and explicit PHAR" {
  v4HasContainerTool() { return 1; }
  v4ComposerPhar() { printf '%s\n' "$V4_DIR/tools/composer.phar"; }
  v4Compose() { jq -nc '$ARGS.positional' --args -- "$@"; }
  V4_ARGS=(install --no-dev)
  run v4SiteComposer
  assert_success
  [ "$(jq -r '.stdout|fromjson|.[0]' <<< "$output")" = run ]
  [[ "$output" == *joomlaabc* ]]
  [[ "$output" == *composer.phar* ]]
}

@test "v4 tools: npm requires a real available tool service" {
  v4HasContainerTool() { return 1; }
  run -127 v4SiteNpm
  assert_status 127
}

@test "v4 tools: optional Node tooling uses an on-demand container" {
  local metadata="$VDM_REPO_PATH/joomla/available/abc.test/project.json"
  jq '.services.node=true' "$metadata" > "$metadata.tmp"
  mv "$metadata.tmp" "$metadata"
  v4HasContainerTool() { return 1; }
  v4Compose() { jq -nc '$ARGS.positional' --args -- "$@"; }
  V4_ARGS=(run build)
  run v4SiteNpm
  assert_success
  [ "$(jq -r '.stdout|fromjson|.[0]' <<< "$output")" = run ]
  [[ "$output" == *nodeabc* ]]
}

@test "v4 tools: offline preparation caches tools profile and honors lifecycle hooks" {
  v4HostsEntry() { printf '%s\n' "hosts:$*" >> "$STUB_DIR/offline"; }
  v4Compose() { printf '%s\n' "$*" >> "$STUB_DIR/offline"; }
  v4RunHook() { printf '%s\n' "hook:$1" >> "$STUB_DIR/offline"; }
  v4WaitReady() { printf '%s\n' "ready:$1" >> "$STUB_DIR/offline"; }
  run v4SiteOffline
  assert_success
  [ "$(jq .hosts_entry_present <<< "$output")" = true ]
  grep -qx -- '--profile tools pull' "$STUB_DIR/offline"
  grep -qx -- 'hook:pre-start' "$STUB_DIR/offline"
  grep -qx -- 'hook:post-start' "$STUB_DIR/offline"
  [ ! -d "$VDM_REPO_PATH/joomla/available/abc.test/.operation.lock" ]
}

@test "v4 tools: update checker rejects untrusted branch input" {
  V4_REQUEST='{"channel":"../../other"}'
  run v4UpdateCheck
  assert_status 2
  refute_command '^curl '
}
