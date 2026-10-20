#!/usr/bin/env bats
# The loader supplies functions that use these globals and invoke test doubles.
# Each Bats test runs in its own subshell; PHP/Compose fixtures retain literals.
# shellcheck disable=SC2034,SC2030,SC2031,SC2317,SC2329,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  V4_REQUEST='{}'
  V4_HOST=example.test; V4_KEY=example; V4_ENV_KEY=EXAMPLE
  V4_DIR="$VDM_REPO_PATH/joomla/available/$V4_HOST"
  V4_PROJECT="$VDM_PROJECT_PATH/$V4_KEY"; V4_DOCROOT="$V4_PROJECT/public/joomla"
  V4_COMPOSE="$V4_DIR/docker-compose.yml"; V4_ENV_FILE="$V4_DIR/.env"
  V4_DB_ENGINE=mariadb; V4_DB_SERVICE=mariadbexample; V4_WEB_SERVICE=joomlaexample
  mkdir -p "$V4_DIR" "$V4_DOCROOT" "$V4_PROJECT/db"
  V4_META=$(jq -cn --arg project "$V4_PROJECT" '{schema_version:1,host:"example.test",key:"example",env_key:"EXAMPLE",project_dir:$project,docroot:"public/joomla",image:"joomla:5.4.9-php8.3-apache",joomla_version:"5.4.9",php_version:"8.3",webserver:"apache",profile:"local",http_port:0,install:true,database:{engine:"mariadb",version:"11.4",name:"joomla",user:"joomla"},tls:{mode:"none"},services:{mail:false,redis:false,node:false},hooks:{},php_settings:{}}')
  printf '%s\n' "$V4_META" > "$V4_DIR/project.json"
  printf 'VDM_PROJECT_PATH="%s"\nVDM_EXAMPLE_DB="joomla"\nVDM_EXAMPLE_DB_USER="joomla"\nVDM_EXAMPLE_DB_PASS="test-secret"\nVDM_EXAMPLE_DB_ROOT="root-secret"\n' "$VDM_PROJECT_PATH" > "$V4_ENV_FILE"
}

@test "runtime generates local Apache Compose with private tools and scoped secrets" {
  v4GenerateCompose
  jq -e '.services.joomlaexample.image=="joomla:5.4.9-php8.3-apache" and .services.joomlaexample.ports[0].host_ip=="127.0.0.1" and .services.joomlaexample.ports[0].published=="0" and .services.joomlaexample.environment.JOOMLA_DB_PASSWORD=="${VDM_EXAMPLE_DB_PASS}" and .services.mariadbexample.environment.MARIADB_ROOT_PASSWORD=="${VDM_EXAMPLE_DB_ROOT}" and .services.phpmyadminexample.ports[0].host_ip=="127.0.0.1"' "$V4_COMPOSE"
  jq -er '.services.joomlaexample.healthcheck.test[-1]' "$V4_COMPOSE" | grep -F '$$s='
  if ! is_windows; then [ "$(file_mode "$V4_COMPOSE")" = 600 ]; fi
  run ! grep -E 'test-secret|root-secret' "$V4_COMPOSE"
}

@test "runtime selects MySQL and PostgreSQL drivers without cross-engine aliases" {
  for engine in mysql postgres; do
    V4_META=$(jq --arg engine "$engine" '.database.engine=$engine | .database.version="16"' <<< "$V4_META")
    v4GenerateCompose
    jq -e --arg db "${engine}example" '.services[$db].image != null' "$V4_COMPOSE"
    if [ "$engine" = postgres ]; then
      jq -e '.services.postgresexample.environment.POSTGRES_PASSWORD=="${VDM_EXAMPLE_DB_PASS}" and .services.joomlaexample.environment.JOOMLA_DB_TYPE=="pgsql" and .services.joomlaexample.environment.JOOMLA_DB_HOST=="postgresexample:5432" and .services.adminerexample!=null and .services.phpmyadminexample==null' "$V4_COMPOSE"
    else jq -e '.services.mysqlexample.environment.MYSQL_DATABASE=="${VDM_EXAMPLE_DB}" and .services.joomlaexample.environment.JOOMLA_DB_TYPE=="mysqli"' "$V4_COMPOSE"; fi
  done
}

@test "database viewer defaults remain compatible and explicit disabled stays disabled" {
  run v4DatabaseUiConfig
  assert_success
  jq -e '.enabled and .provider=="phpmyadmin" and .service=="phpmyadminexample" and .port==80' <<< "$output"
  V4_META=$(jq '.database.engine="postgres" | .services.database_ui=false' <<< "$V4_META")
  run v4DatabaseUiConfig
  assert_success
  jq -e '.enabled==false and .provider=="adminer" and .service=="adminerexample" and .port==8080' <<< "$output"
  v4GenerateCompose
  jq -e '.services.phpmyadminexample==null and .services.adminerexample==null and .services.postgresexample!=null' "$V4_COMPOSE"
}

@test "database viewer generation supports either provider for MySQL family with private healthy ports" {
  local engine provider port
  for engine in mariadb mysql; do
    for provider in phpmyadmin adminer; do
      V4_META=$(jq --arg engine "$engine" --arg provider "$provider" '.database.engine=$engine | .services.database_viewer=$provider | .services.database_ui=true' <<< "$V4_META")
      v4GenerateCompose
      port=80; [ "$provider" != adminer ] || port=8080
      jq -e --arg provider "$provider" --arg db "${engine}example" --argjson port "$port" '
        .services[($provider+"example")] as $viewer |
        $viewer.image==($provider+":5") and $viewer.container_name==($provider+"example") and
        $viewer.labels["traefik.enable"]=="false" and $viewer.labels["io.octojoom.site"]=="example.test" and
        $viewer.ports[0].host_ip=="127.0.0.1" and $viewer.ports[0].target==$port and
        ($viewer.healthcheck.test[-1]|contains("$$s=@fsockopen")) and
        (if $provider=="adminer" then $viewer.environment.ADMINER_DEFAULT_SERVER==$db and .services.phpmyadminexample==null
         else $viewer.environment.PMA_HOST==$db and .services.adminerexample==null end)' "$V4_COMPOSE"
      v4RuntimeValidateDatabaseUiCompose "$(cat "$V4_COMPOSE")"
    done
  done
}

@test "database viewer rejects incompatible providers and malformed controls before generation" {
  v4GenerateCompose
  cp "$V4_COMPOSE" "$SANDBOX/compose-before"
  local original="$V4_META" invalid
  for invalid in '{"database_ui":"false"}' '{"database_ui":null}' '{"database_viewer":"unknown"}' '{"database_viewer":null}'; do
    V4_META=$(jq --argjson invalid "$invalid" '.services += $invalid' <<< "$original")
    run v4GenerateCompose
    assert_status 2
    cmp "$SANDBOX/compose-before" "$V4_COMPOSE"
  done
  V4_META=$(jq '.database.engine="postgres" | .services.database_viewer="phpmyadmin" | .services.database_ui=false' <<< "$original")
  run v4GenerateCompose
  assert_status 2
  [[ "$output" == *'phpMyAdmin does not support PostgreSQL'* ]]
  cmp "$SANDBOX/compose-before" "$V4_COMPOSE"
}

@test "database viewer overrides cannot resurrect disabled services or change private database targets" {
  v4GenerateCompose
  local original="$V4_META" config
  config=$(cat "$V4_COMPOSE")
  V4_META=$(jq '.services.database_ui=false' <<< "$original")
  run v4RuntimeValidateDatabaseUiCompose "$config"
  assert_status 2
  V4_META=$(jq '.services.database_viewer="adminer"' <<< "$original")
  run v4RuntimeValidateDatabaseUiCompose "$config"
  assert_status 2
  V4_META="$original"
  run v4RuntimeValidateDatabaseUiCompose "$(jq '.services.phpmyadminexample.ports[0].host_ip="0.0.0.0"' <<< "$config")"
  assert_status 2
  run v4RuntimeValidateDatabaseUiCompose "$(jq '.services.phpmyadminexample.environment.PMA_HOST="another-site"' <<< "$config")"
  assert_status 2
  local service
  for service in mailpitexample redisexample nodeexample; do
    run v4RuntimeValidateDatabaseUiCompose "$(jq --arg service "$service" '.services[$service]={image:"override:latest"}' <<< "$config")"
    assert_status 2
  done
  v4RuntimeValidateDatabaseUiCompose "$config"
}

@test "failed database viewer swap restores prior provider and originally running services" {
  v4GenerateCompose
  cp "$V4_COMPOSE" "$SANDBOX/compose-before"
  cp "$V4_DIR/project.json" "$SANDBOX/meta-before"
  printf 'database untouched' > "$V4_PROJECT/db/marker"
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) printf '{"services":{}}'; exit 0;;
  *' ps '*) printf 'mariadbexample\njoomlaexample\nphpmyadminexample\n'; exit 0;;
  *' up '*)
    if [ ! -f "$STUB_DIR/first-up" ]; then touch "$STUB_DIR/first-up"; exit 1; fi
    printf '%s\n' "$*" > "$STUB_DIR/restored-up"
    exit 0;;
esac
exit 0
HOOK
  run v4ApplyConfig "$(jq '.services.database_viewer="adminer"' <<< "$V4_META")"
  assert_failure
  cmp "$SANDBOX/compose-before" "$V4_COMPOSE"
  cmp "$SANDBOX/meta-before" "$V4_DIR/project.json"
  grep -F -- '--remove-orphans --wait --wait-timeout 180 mariadbexample joomlaexample phpmyadminexample' "$STUB_DIR/restored-up"
  [ "$(cat "$V4_PROJECT/db/marker")" = 'database untouched' ]
}

@test "stopped database viewer disable and swap remove only the owned old container without starting the site" {
  local original="$V4_META" request
  printf 'database untouched' > "$V4_PROJECT/db/marker"
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) printf '{"name":"octojoomexample","services":{}}';;
  *' ps --all --quiet phpmyadminexample'*) [ -f "$STUB_DIR/removed-viewer" ] || printf 'abcdef123456\r\n';;
  'container inspect abcdef123456') printf '[{"Name":"/phpmyadminexample","State":{"Running":false,"Restarting":false},"Config":{"Labels":{"com.docker.compose.project":"octojoomexample","com.docker.compose.service":"phpmyadminexample"}}}]';;
  *' rm -f phpmyadminexample') touch "$STUB_DIR/removed-viewer";;
esac
exit 0
HOOK
  for request in '{"database_ui":false}' '{"database_viewer":"adminer"}'; do
    V4_META="$original"
    printf '%s\n' "$V4_META" > "$V4_DIR/project.json"
    v4GenerateCompose
    rm -f "$STUB_DIR/removed-viewer"
    : > "$STUB_DIR/commands.log"
    run v4ApplyConfig "$(jq --argjson request "$request" '.services += $request' <<< "$V4_META")"
    assert_success
    [ -f "$STUB_DIR/removed-viewer" ]
    grep -F ' rm -f phpmyadminexample' "$STUB_DIR/commands.log"
    run ! grep -E ' (up|down) | rm .* -v' "$STUB_DIR/commands.log"
    [ "$(cat "$V4_PROJECT/db/marker")" = 'database untouched' ]
  done
}

@test "stopped database viewer removal refuses foreign ownership and restores prior metadata" {
  v4GenerateCompose
  cp "$V4_COMPOSE" "$SANDBOX/compose-before"
  cp "$V4_DIR/project.json" "$SANDBOX/meta-before"
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) printf '{"name":"octojoomexample","services":{}}';;
  *' ps --all --quiet phpmyadminexample'*) printf 'abcdef123456';;
  'container inspect abcdef123456') printf '[{"Name":"/phpmyadminexample","State":{"Running":false,"Restarting":false},"Config":{"Labels":{"com.docker.compose.project":"someoneelse","com.docker.compose.service":"phpmyadminexample"}}}]';;
esac
exit 0
HOOK
  run v4ApplyConfig "$(jq '.services.database_ui=false' <<< "$V4_META")"
  assert_status 3
  [[ "$output" == *'not owned by this Compose project'* ]]
  cmp "$SANDBOX/compose-before" "$V4_COMPOSE"
  cmp "$SANDBOX/meta-before" "$V4_DIR/project.json"
  run ! grep -E ' (rm|up|down) ' "$STUB_DIR/commands.log"
}

@test "failed stopped viewer removal restores configuration and leaves the site stopped" {
  v4GenerateCompose
  cp "$V4_COMPOSE" "$SANDBOX/compose-before"
  cp "$V4_DIR/project.json" "$SANDBOX/meta-before"
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) printf '{"name":"octojoomexample","services":{}}';;
  *' ps --all --quiet phpmyadminexample'*) printf 'abcdef123456';;
  'container inspect abcdef123456') printf '[{"Name":"/phpmyadminexample","State":{"Running":false,"Restarting":false},"Config":{"Labels":{"com.docker.compose.project":"octojoomexample","com.docker.compose.service":"phpmyadminexample"}}}]';;
  *' rm -f phpmyadminexample') exit 1;;
esac
exit 0
HOOK
  run v4ApplyConfig "$(jq '.services.database_ui=false' <<< "$V4_META")"
  assert_failure
  cmp "$SANDBOX/compose-before" "$V4_COMPOSE"
  cmp "$SANDBOX/meta-before" "$V4_DIR/project.json"
  run ! grep -E ' (up|down) ' "$STUB_DIR/commands.log"
  [ ! -e "$V4_DIR/.operation.lock" ]
}

@test "failed route publication leaves the original stopped database viewer intact" {
  v4GenerateCompose
  cp "$V4_COMPOSE" "$SANDBOX/compose-before"
  cp "$V4_DIR/project.json" "$SANDBOX/meta-before"
  v4NetworkSyncRoute() { return 1; }
  v4RuntimeRemoveStoppedServices() { touch "$SANDBOX/should-not-remove-viewer"; }
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) printf '{"services":{}}';;
esac
exit 0
HOOK
  run v4ApplyConfig "$(jq '.services.database_ui=false' <<< "$V4_META")"
  assert_failure
  cmp "$SANDBOX/compose-before" "$V4_COMPOSE"
  cmp "$SANDBOX/meta-before" "$V4_DIR/project.json"
  [ ! -e "$SANDBOX/should-not-remove-viewer" ]
  run ! grep -E ' (up|down) ' "$STUB_DIR/commands.log"
}

@test "stopped mail Redis and Node disable remove only owned optional containers" {
  local original="$V4_META" option role
  printf 'database untouched' > "$V4_PROJECT/db/marker"
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) cat "$SANDBOX/prior-compose.json";;
  *' ps --all --quiet '*) [ -f "$STUB_DIR/removed-service" ] || printf 'abcdef123456';;
  'container inspect abcdef123456')
    jq -n --arg service "$OCTOJOOM_TEST_SERVICE" '[{Name:(if $service=="nodeexample" then "/octojoomexample-nodeexample-1" else "/"+$service end),State:{Running:false,Restarting:false},Config:{Labels:{"com.docker.compose.project":"octojoomexample","com.docker.compose.service":$service,"com.docker.compose.oneoff":"False"}}}]';;
  *' rm -f '*) printf '%s\n' "$*" > "$STUB_DIR/removed-service";;
esac
exit 0
HOOK
  for option in mail redis node; do
    V4_META=$(jq --arg option "$option" '.services[$option]=true' <<< "$original")
    printf '%s\n' "$V4_META" > "$V4_DIR/project.json"
    v4GenerateCompose
    cp "$V4_COMPOSE" "$SANDBOX/prior-compose.json"
    role="$option"; [ "$role" != mail ] || role=mailpit
    export OCTOJOOM_TEST_SERVICE="${role}example"
    rm -f "$STUB_DIR/removed-service"
    : > "$STUB_DIR/commands.log"
    run v4ApplyConfig "$(jq --arg option "$option" '.services[$option]=false' <<< "$V4_META")"
    assert_success
    grep -F -- " rm -f ${role}example" "$STUB_DIR/removed-service"
    run ! grep -E ' (up|down) | rm .* -v' "$STUB_DIR/commands.log"
    [ "$(cat "$V4_PROJECT/db/marker")" = 'database untouched' ]
  done
}

@test "stopped optional cleanup validates every owner before removing any container" {
  local previous
  previous=$(jq '.services.mail=true | .services.redis=true' <<< "$V4_META")
  V4_META=$(jq '.services.mail=false | .services.redis=false' <<< "$previous")
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) printf '{"name":"octojoomexample","services":{}}';;
  *' ps --all --quiet mailpitexample') printf 'aaaaaa';;
  *' ps --all --quiet redisexample') printf 'bbbbbb';;
  'container inspect aaaaaa') printf '[{"Name":"/mailpitexample","State":{"Running":false,"Restarting":false},"Config":{"Labels":{"com.docker.compose.project":"octojoomexample","com.docker.compose.service":"mailpitexample"}}}]';;
  'container inspect bbbbbb') printf '[{"Name":"/redisexample","State":{"Running":false,"Restarting":false},"Config":{"Labels":{"com.docker.compose.project":"foreign","com.docker.compose.service":"redisexample"}}}]';;
esac
exit 0
HOOK
  run v4RuntimeRemoveStoppedServices "$V4_COMPOSE" "$previous"
  assert_status 3
  [[ "$output" == *'nothing was removed'* ]]
  run ! grep -F ' rm ' "$STUB_DIR/commands.log"
}

@test "outer TLS transactions can defer stopped cleanup until final verification" {
  v4GenerateCompose
  v4RuntimeRemoveStoppedServices() { touch "$SANDBOX/should-not-remove-service"; }
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) printf '{"services":{}}';;
esac
exit 0
HOOK
  V4_DEFER_STOPPED_CLEANUP=true run v4ApplyConfig "$(jq '.services.database_ui=false' <<< "$V4_META")"
  assert_success
  [ ! -e "$SANDBOX/should-not-remove-service" ]
  jq -e '.services.database_ui==false' "$V4_DIR/project.json"
  run ! grep -E ' (up|down|rm) ' "$STUB_DIR/commands.log"
}

@test "contradictory viewer override is rejected before publishing new configuration" {
  v4GenerateCompose
  cp "$V4_COMPOSE" "$SANDBOX/compose-before"
  cp "$V4_DIR/project.json" "$SANDBOX/meta-before"
  printf 'services:\n  phpmyadminexample:\n    environment:\n      USER_SETTING: retained\n' > "$V4_DIR/docker-compose.override.yml"
  cp "$V4_DIR/docker-compose.override.yml" "$SANDBOX/override-before"
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) cat "$SANDBOX/compose-before";;
esac
exit 0
HOOK
  run v4ApplyConfig "$(jq '.services.database_ui=false' <<< "$V4_META")"
  assert_status 2
  [[ "$output" == *'Compose override conflicts'* ]]
  cmp "$SANDBOX/compose-before" "$V4_COMPOSE"
  cmp "$SANDBOX/meta-before" "$V4_DIR/project.json"
  cmp "$SANDBOX/override-before" "$V4_DIR/docker-compose.override.yml"
  run ! grep -E ' (rm|up|down|stop) ' "$STUB_DIR/commands.log"
}

@test "nginx routes Joomla API PATH_INFO to FPM with custom docroot and private config" {
  V4_META=$(jq '.webserver="nginx" | .image="joomla:5.4.9-php8.3-fpm"' <<< "$V4_META")
  v4GenerateCompose
  jq -e --arg root "$(v4DockerHostPath "$V4_DOCROOT")" '.services.nginxexample.ports[0].host_ip=="127.0.0.1" and .services.joomlaexample.ports==null and .services.joomlaexample.volumes[0].source==$root and .services.nginxexample.volumes[0].source==$root and .services.nginxexample.volumes[0].read_only==true' "$V4_COMPOSE"
  grep -F 'location /api/' "$V4_DIR/nginx.generated.conf"
  grep -F 'fastcgi_param PATH_INFO $octojoom_path_info;' "$V4_DIR/nginx.generated.conf"
  grep -F 'location ~ ^/configuration\.php(/|$) { deny all; }' "$V4_DIR/nginx.generated.conf"
}

@test "runtime rejects traversal and symlink project paths before generation" {
  run v4RuntimeValidateMeta "$(jq '.docroot="../outside"' <<< "$V4_META")"
  assert_status 2
  run v4RuntimeValidateMeta "$(jq '.docroot="db/joomla"' <<< "$V4_META")"
  assert_status 2
  ln -s "$V4_PROJECT" "$VDM_PROJECT_PATH/redirect"
  run v4RuntimeValidateMeta "$(jq --arg path "$VDM_PROJECT_PATH/redirect/child" '.project_dir=$path' <<< "$V4_META")"
  assert_status 2
}

@test "runtime PHP overrides reject injection and preserve generated configuration" {
  v4GenerateCompose
  cp "$V4_DIR/php.generated.ini" "$SANDBOX/before"
  V4_META=$(jq '.php_settings.memory_limit="512M\nauto_prepend_file=bad.php"' <<< "$V4_META")
  run v4GenerateCompose
  assert_status 2
  cmp "$SANDBOX/before" "$V4_DIR/php.generated.ini"
}

@test "runtime reserves unique keys across hosts and never removes an existing project" {
  v4GenerateCompose
  local target
  target=$(jq --arg path "$VDM_PROJECT_PATH/otherroot/example" '.host="other.test" | .project_dir=$path' <<< "$V4_META")
  cp "$V4_ENV_FILE" "$SANDBOX/other.env"
  v4SetEnv "$SANDBOX/other.env" "VDM_PROJECT_PATH=\"$VDM_PROJECT_PATH/otherroot\""
  run v4ProvisionMetadata "$target" "$SANDBOX/other.env"
  assert_status 3
  [ -d "$V4_PROJECT" ]
  [ ! -e "$VDM_PROJECT_PATH/otherroot/example" ]
  [ ! -e "$VDM_REPO_PATH/joomla/available/other.test" ]
  [ ! -e "$VDM_REPO_PATH/joomla/.provision.lock" ]
}

@test "runtime refuses in-place database replacement without changing files" {
  v4GenerateCompose
  cp "$V4_COMPOSE" "$SANDBOX/before"
  run v4ApplyConfig "$(jq '.database.engine="mysql" | .database.version="8.4"' <<< "$V4_META")"
  assert_status 2
  cmp "$SANDBOX/before" "$V4_COMPOSE"
  [ ! -e "$V4_DIR/.operation.lock" ]
}

@test "runtime regeneration leaves companion overrides intact" {
  printf 'services:\n  joomlaexample:\n    environment:\n      USER_OVERRIDE: yes\n' > "$V4_DIR/docker-compose.override.yml"
  cp "$V4_DIR/docker-compose.override.yml" "$SANDBOX/override"
  v4GenerateCompose
  v4GenerateCompose
  cmp "$SANDBOX/override" "$V4_DIR/docker-compose.override.yml"
}

@test "image validation rejects different Joomla patch and missing database extension" {
  hook_command docker <<'HOOK'
if [ "$1" = image ]; then exit 0; fi
case "$*" in
  *PHP_MAJOR_VERSION*) printf '8.3';;
  *simplexml_load_file*) printf '5.4.8';;
esac
exit 0
HOOK
  run v4RuntimeValidateImage "$V4_META"
  assert_status 2
  [[ "$output" == *'requested Joomla version'* ]]
  hook_command docker <<'HOOK'
if [ "$1" = image ]; then exit 0; fi
case "$*" in
  *PHP_MAJOR_VERSION*) printf '8.3';;
  *extension_loaded*) exit 1;;
esac
exit 0
HOOK
  run v4RuntimeValidateImage "$V4_META"
  assert_status 2
  [[ "$output" == *'mysqli extension'* ]]
}

@test "new-site credentials are private, generated, and safely round trip special characters" {
  V4_REQUEST='{"admin_email":"admin@example.test","database_password":"p$word\\quoted\"value","admin_password":"long-enough-admin-pass"}'
  v4RuntimeCreateEnv "$V4_META" "$SANDBOX/credentials"
  if ! is_windows; then [ "$(file_mode "$SANDBOX/credentials")" = 600 ]; fi
  local password root
  migrationReadEnvValue "$SANDBOX/credentials" VDM_EXAMPLE_DB_PASS password
  [ "$password" = 'p$word\quoted"value' ]
  migrationReadEnvValue "$SANDBOX/credentials" VDM_EXAMPLE_DB_ROOT root
  [ "${#root}" -ge 30 ]
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "source packages require HTTPS and SHA256 before any download" {
  mkdir "$SANDBOX/empty"
  run v4RuntimeDownloadSource http://example.test/joomla.zip "$SANDBOX/empty" "$(printf 'a%.0s' {1..64})"
  assert_status 2
  run v4RuntimeDownloadSource https://example.test/joomla.zip "$SANDBOX/empty"
  assert_status 2
  run ! grep 'curl' "$STUB_DIR/commands.log"
}

@test "long site keys use bounded Joomla table prefixes" {
  V4_META=$(jq '.key="averylongprojectidentifier"' <<< "$V4_META")
  v4GenerateCompose
  jq -e '.services.joomlaaverylongprojectidentifier.environment.JOOMLA_DB_PREFIX | length <= 15' "$V4_COMPOSE"
}

@test "runtime metadata carries create service options and explicit server network" {
  V4_REQUEST='{"site":"demo-site.test","joomla_version":"5.4.9","php_version":"8.3","mail":true,"redis":true,"node":true,"network":"custom_proxy","mail_port":8027}'
  local meta
  meta=$(v4RuntimeNewMetadata)
  v4RuntimeValidateMeta "$meta"
  jq -e '.key=="demo-site" and .env_key=="DEMO_SITE" and .services.mail and .services.redis and .services.node and .services.mail_port==8027 and .network=="custom_proxy"' <<< "$meta"
}

@test "PostgreSQL 18 uses versioned data directory parent mount" {
  V4_META=$(jq '.database.engine="postgres" | .database.version="18.1"' <<< "$V4_META")
  v4GenerateCompose
  jq -e '.services.postgresexample.volumes[0].target=="/var/lib/postgresql"' "$V4_COMPOSE"
}

@test "failed runtime recreate restores metadata and service selection from native CRLF output" {
  v4GenerateCompose
  cp "$V4_COMPOSE" "$SANDBOX/compose-before"
  cp "$V4_DIR/project.json" "$SANDBOX/meta-before"
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) printf '{"services":{}}'; exit 0;;
  *' ps '*) printf 'mariadbexample\r\njoomlaexample\r\n'; exit 0;;
  *' up '*)
    if [ ! -f "$STUB_DIR/first-up" ]; then touch "$STUB_DIR/first-up"; exit 1; fi
    printf '%s\n' "$*" > "$STUB_DIR/restored-up"
    exit 0;;
esac
exit 0
HOOK
  run v4ApplyConfig "$(jq '.php_settings.memory_limit="512M"' <<< "$V4_META")"
  assert_failure
  cmp "$SANDBOX/compose-before" "$V4_COMPOSE"
  cmp "$SANDBOX/meta-before" "$V4_DIR/project.json"
  grep -F 'mariadbexample joomlaexample' "$STUB_DIR/restored-up"
  run ! grep -F $'\r' "$STUB_DIR/restored-up"
  [ ! -e "$V4_DIR/.operation.lock" ]
}

@test "runtime PHP switch pins the installed Joomla patch while changing only PHP image" {
  mkdir -p "$V4_DOCROOT/administrator/manifests/files"
  printf '<version>5.4.9</version>\n' > "$V4_DOCROOT/administrator/manifests/files/joomla.xml"
  v4GenerateCompose
  V4_REQUEST='{"site":"example.test","php_version":"8.4","yes":true}'
  v4RuntimeValidateImage() { printf '%s' "$1" > "$SANDBOX/validated"; }
  v4ApplyConfig() { printf '%s' "$1" > "$SANDBOX/applied"; }
  run v4SitePhp
  assert_success
  jq -e '.image=="joomla:5.4.9-php8.4-apache" and .joomla_version=="5.4.9"' "$SANDBOX/validated"
  cmp "$SANDBOX/validated" "$SANDBOX/applied"
  [ "$(cat "$V4_DOCROOT/administrator/manifests/files/joomla.xml")" = '<version>5.4.9</version>' ]
}

@test "realignment changes only Joomla literal properties without executing configuration" {
  local php_binary="${V4_TEST_PHP:-php}"
  command -v "$php_binary" >/dev/null || skip 'PHP CLI is required for the embedded realignment editor test'
  export V4_TEST_PHP="$php_binary"
  cat > "$V4_DOCROOT/configuration.php" <<'PHP'
<?php
file_put_contents('/tmp/octojoom-must-never-execute', 'bad');
class JConfig {
 public $host = 'remote';
 public $db = 'production';
 public $user = 'remote';
 public $password = 'remote';
 public $dbtype = 'mysql';
 public $log_path = '/logs';
 public $tmp_path = '/tmp';
 public $live_site = 'https://production.invalid';
 public $cookie_domain = 'production.invalid';
 public $force_ssl = 2;
 public $behind_loadbalancer = false;
 public $untouched = 'preserve me';
}
PHP
  # Inject the sandbox marker as data; the editor must never execute PHP config.
  local fixture marker="$SANDBOX/must-never-execute"
  if is_windows; then marker=$(cygpath -m "$marker"); fi
  fixture=$(cat "$V4_DOCROOT/configuration.php")
  printf '%s\n' "${fixture//\/tmp\/octojoom-must-never-execute/$marker}" > "$V4_DOCROOT/configuration.php"
  chmod 640 "$V4_DOCROOT/configuration.php"
  v4Compose() {
    local code="${*: -1}" php_root="$V4_DOCROOT"
    if is_windows; then php_root=$(cygpath -m "$php_root"); fi
    code="${code//\/var\/www\/html/$php_root}"
    "$V4_TEST_PHP" -r "$code"
  }
  run v4RealignConfiguration
  assert_success
  grep -F "public \$host = 'mariadbexample';" "$V4_DOCROOT/configuration.php"
  grep -F "public \$live_site = '';" "$V4_DOCROOT/configuration.php"
  grep -F 'public $behind_loadbalancer = true;' "$V4_DOCROOT/configuration.php"
  grep -F "public \$untouched = 'preserve me';" "$V4_DOCROOT/configuration.php"
  if ! is_windows; then [ "$(file_mode "$V4_DOCROOT/configuration.php")" = 640 ]; fi
  [ ! -e "$SANDBOX/must-never-execute" ]
}

@test "realignment refuses computed properties and retains the original file" {
  local php_binary="${V4_TEST_PHP:-php}"
  command -v "$php_binary" >/dev/null || skip 'PHP CLI is required for the embedded realignment editor test'
  export V4_TEST_PHP="$php_binary"
  printf '<?php class JConfig { public $host = getenv("SECRET_HOST"); }\n' > "$V4_DOCROOT/configuration.php"
  cp "$V4_DOCROOT/configuration.php" "$SANDBOX/config-before"
  v4Compose() {
    local code="${*: -1}" php_root="$V4_DOCROOT"
    if is_windows; then php_root=$(cygpath -m "$php_root"); fi
    code="${code//\/var\/www\/html/$php_root}"
    "$V4_TEST_PHP" -r "$code"
  }
  run v4RealignConfiguration
  assert_failure
  cmp "$SANDBOX/config-before" "$V4_DOCROOT/configuration.php"
}

@test "runtime image preflight never refreshes the already installed database tag" {
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) printf '{"services":{"db":{"image":"mariadb:11.4"},"web":{"image":"joomla:5.4.9-php8.3-apache"},"built":{"image":"custom-build:local","build":"."}}}';;
  'image inspect mariadb:11.4') exit 0;;
  'image inspect joomla:5.4.9-php8.3-apache') exit 1;;
  'pull joomla:5.4.9-php8.3-apache') exit 0;;
  *) exit 1;;
esac
HOOK
  run v4RuntimePrepareImages "$V4_COMPOSE"
  assert_success
  run ! grep -F 'pull mariadb:' "$STUB_DIR/commands.log"
  run ! grep -F 'pull custom-build:' "$STUB_DIR/commands.log"
  grep -F 'pull joomla:5.4.9-php8.3-apache' "$STUB_DIR/commands.log"
}

@test "official download resolves only the full stable asset and verifies release SHA256" {
  local digest
  digest=$(printf 'a%.0s' {1..64})
  jq -cn --arg digest "$digest" '{draft:false,prerelease:false,tag_name:"6.2.0",assets:[{name:"Joomla_6.2.0-Stable-Full_Package.tar.gz",browser_download_url:"https://github.com/joomla/joomla-cms/releases/download/6.2.0/Joomla_6.2.0-Stable-Full_Package.tar.gz",digest:("sha256:"+$digest)},{name:"Joomla_6.2.0-Stable-Update_Package.tar.gz",digest:"sha256:bad"}]}' > "$SANDBOX/release.json"
  hook_command curl <<'HOOK'
cat "$SANDBOX/release.json"
HOOK
  run v4RuntimeOfficialPackage latest
  assert_success
  jq -e --arg digest "$digest" '.version=="6.2.0" and .sha256==$digest and (.url|endswith("Full_Package.tar.gz"))' <<< "$output"
  jq '.prerelease=true' "$SANDBOX/release.json" > "$SANDBOX/invalid.json"
  mv "$SANDBOX/invalid.json" "$SANDBOX/release.json"
  run v4RuntimeOfficialPackage latest
  assert_status 2
}

@test "official download accepts a matching published SHA256 when asset digest is unavailable" {
  local digest url
  digest=$(printf 'b%.0s' {1..64}); url='https://github.com/joomla/joomla-cms/releases/download/5.4.9/Joomla_5.4.9-Stable-Full_Package.tar.gz'
  jq -cn --arg digest "$digest" --arg url "$url" '{draft:false,prerelease:false,tag_name:"5.4.9",body:("| [GNU Zip Archive]("+$url+") | `"+$digest+"` |"),assets:[{name:"Joomla_5.4.9-Stable-Full_Package.tar.gz",browser_download_url:$url,digest:null}]}' > "$SANDBOX/release.json"
  hook_command curl <<'HOOK'
cat "$SANDBOX/release.json"
HOOK
  run v4RuntimeOfficialPackage 5.4.9
  assert_success
  jq -e --arg digest "$digest" '.sha256==$digest' <<< "$output"
}

@test "standalone custom download verifies and extracts fresh Joomla without Docker" {
  mkdir -p "$SANDBOX/package/administrator/manifests/files"
  printf '<version>5.4.9</version>\n' > "$SANDBOX/package/administrator/manifests/files/joomla.xml"
  printf '<?php echo "Joomla";\n' > "$SANDBOX/package/index.php"
  tar -czf "$SANDBOX/joomla.tar.gz" -C "$SANDBOX/package" .
  local checksum
  checksum=$(v4Digest "$SANDBOX/joomla.tar.gz")
  V4_REQUEST=$(jq -cn --arg output "$SANDBOX/download" --arg checksum "$checksum" '{output:$output,package_url:"https://packages.example.test/joomla.tar.gz",source_sha256:$checksum,joomla_version:"5.4.9"}')
  hook_command curl <<'HOOK'
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then cp "$SANDBOX/joomla.tar.gz" "$2"; exit $?; fi
  shift
done
exit 1
HOOK
  run v4SiteDownload
  assert_success
  [ -f "$SANDBOX/download/index.php" ]
  if ! is_windows; then [ "$(file_mode "$SANDBOX/download/index.php")" = 644 ]; fi
  run ! grep -F 'docker ' "$STUB_DIR/commands.log"
  run v4SiteDownload
  assert_status 2
  [ -f "$SANDBOX/download/index.php" ]
}

@test "failed standalone checksum leaves a preexisting empty output directory untouched" {
  mkdir "$SANDBOX/download"
  V4_REQUEST=$(jq -cn --arg output "$SANDBOX/download" --arg checksum "$(printf 'a%.0s' {1..64})" '{output:$output,package_url:"https://packages.example.test/joomla.tar.gz",source_sha256:$checksum}')
  hook_command curl <<'HOOK'
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then printf invalid > "$2"; exit 0; fi
  shift
done
exit 1
HOOK
  run v4SiteDownload
  assert_status 2
  [ -d "$SANDBOX/download" ]
  [ -z "$(find "$SANDBOX/download" -mindepth 1 -print -quit)" ]
  [ ! -e "$SANDBOX/download.download.lock" ]
}

@test "runtime apply synchronizes the TLS frontend after switching Apache to Nginx" {
  v4GenerateCompose
  v4NetworkSyncRoute() { jq -r '.webserver' <<< "$V4_META" > "$SANDBOX/route-server"; }
  hook_command docker <<'HOOK'
case "$*" in
  *' config --format json'*) printf '{"services":{}}';;
esac
exit 0
HOOK
  run v4ApplyConfig "$(jq '.webserver="nginx" | .image="joomla:5.4.9-php8.3-fpm"' <<< "$V4_META")"
  assert_success
  [ "$(cat "$SANDBOX/route-server")" = nginx ]
}

@test "webserver switch refuses an active review tunnel before image or runtime changes" {
  v4GenerateCompose
  V4_REQUEST='{"site":"example.test","webserver":"nginx","yes":true}'
  v4ShareRunning() { return 0; }
  v4RuntimeValidateImage() { touch "$SANDBOX/image-touched"; }
  v4ApplyConfig() { touch "$SANDBOX/config-touched"; }
  run v4SiteWebserver
  assert_status 2
  [[ "$output" == *'Stop the active share'* ]]
  [ ! -e "$SANDBOX/image-touched" ]
  [ ! -e "$SANDBOX/config-touched" ]
}

@test "Docker host path conversion uses native Windows paths only on Windows" {
  local original_type="$OSTYPE"
  cygpath() { [ "$1" = -am ] && [ "$2" = -- ] && [ "$3" = '/c/Users/Example Person/site' ] && printf 'C:/Users/Example Person/site\n'; }
  OSTYPE=msys
  run v4DockerHostPath '/c/Users/Example Person/site'
  assert_success
  [ "$output" = 'C:/Users/Example Person/site' ]
  OSTYPE=linux-gnu
  run v4DockerHostPath '/home/example/site'
  assert_success
  [ "$output" = '/home/example/site' ]
  OSTYPE="$original_type"
}

@test "generated Compose converts host bindings while preserving metadata and container paths" {
  v4DockerHostPath() { printf 'C:/Users/Example Person/Projects/example\n'; }
  local original="$V4_META"
  v4GenerateCompose
  jq -e '.services.joomlaexample.volumes[0].source=="C:/Users/Example Person/Projects/example/public/joomla" and .services.joomlaexample.volumes[0].target=="/var/www/html" and .services.mariadbexample.volumes[0].source=="C:/Users/Example Person/Projects/example/db" and .services.mariadbexample.volumes[0].target=="/var/lib/mysql" and .services.joomlaexample.working_dir=="/var/www/html"' "$V4_COMPOSE"
  [ "$V4_META" = "$original" ]
}

@test "native Windows Compose resolves generated host paths without a Docker daemon" {
  is_windows || skip 'Native Windows Compose validation runs on Windows'
  local native_docker
  # This config-only check is independent of daemon-based test exclusions.
  native_docker=$(PATH="${PATH//${HELPERS_DIR}\/bin:/}" type -P docker || true)
  if [ -z "$native_docker" ] || ! "$native_docker" compose version >/dev/null 2>&1; then
    if [ "${OCTOJOOM_REQUIRE_NATIVE_COMPOSE:-}" = 1 ]; then
      printf 'Windows CI requires the native Docker Compose CLI.\n' >&2
      return 1
    fi
    skip 'Native Docker Compose CLI is unavailable'
  fi
  local file env_file expected provider
  file=$(v4DockerHostPath "$V4_COMPOSE"); env_file=$(v4DockerHostPath "$V4_ENV_FILE"); expected=$(v4DockerHostPath "$V4_DOCROOT")
  for provider in phpmyadmin adminer disabled; do
    V4_META=$(jq --arg provider "$provider" 'if $provider=="disabled" then .services.database_ui=false else .services.database_ui=true | .services.database_viewer=$provider end' <<< "$V4_META")
    v4GenerateCompose
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$native_docker" compose --file "$file" --env-file "$env_file" config --format json > "$SANDBOX/resolved-compose.json"
    jq -e --arg expected "$expected" '.services.joomlaexample.volumes[] | select(.target=="/var/www/html") | (.source|gsub("\\\\";"/")|ascii_downcase)==($expected|ascii_downcase) and .target=="/var/www/html"' "$SANDBOX/resolved-compose.json"
    v4RuntimeValidateDatabaseUiCompose "$(cat "$SANDBOX/resolved-compose.json")"
  done
}

@test "managed links are real symbolic links and refuse existing destinations" {
  mkdir "$SANDBOX/link-target"
  run v4CreateLink "$SANDBOX/link-target" "$SANDBOX/managed-link"
  assert_success
  [ -L "$SANDBOX/managed-link" ]
  [ "$(readlink "$SANDBOX/managed-link")" = "$SANDBOX/link-target" ]
  printf original > "$SANDBOX/occupied-link"
  run v4CreateLink "$SANDBOX/link-target" "$SANDBOX/occupied-link"
  assert_status 3
  [ "$(cat "$SANDBOX/occupied-link")" = original ]
}

@test "Windows link failure preserves options and never falls back to a directory copy" {
  ln() { printf '%s' "$MSYS" > "$SANDBOX/link-options"; return 1; }
  MSYS='existing-option' OSTYPE=msys run v4CreateLink "$V4_DIR" "$SANDBOX/managed-link"
  assert_status 3
  [[ "$output" == *'Developer Mode'* ]]
  [ "$(cat "$SANDBOX/link-options")" = 'existing-option winsymlinks:nativestrict' ]
  [ ! -e "$SANDBOX/managed-link" ]
}

@test "create checks native link support before image changes or site publication" {
  V4_REQUEST='{"activate":true}'
  v4RuntimeNewMetadata() { printf '%s\n' "$V4_META"; }
  v4CheckLinkSupport() { return 3; }
  v4RuntimeValidateImage() { touch "$SANDBOX/image-touched"; }
  v4ProvisionMetadata() { touch "$SANDBOX/site-published"; }
  run v4SiteCreate
  assert_status 3
  [ ! -e "$SANDBOX/image-touched" ]
  [ ! -e "$SANDBOX/site-published" ]
}

@test "large hook metadata streams into runtime generation without native argv limits" {
  V4_REQUEST=$(jq -cn '{site:"large.test",key:"large",joomla_version:"5.4.9",php_version:"8.3",install:false,hooks:{"post-start":[["printf",("x"*70000)]]}}')
  V4_META=$(v4RuntimeNewMetadata)
  jq -e '.hooks["post-start"][0][1]|length==70000' <<< "$V4_META"
  v4GenerateCompose
  jq -e '.services.joomlalarge.image=="joomla:5.4.9-php8.3-apache"' "$V4_COMPOSE"
}
