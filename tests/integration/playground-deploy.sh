#!/usr/bin/env bash
# Generate a private complete Playground export from an installed official
# Joomla donor and exercise Octojoom's public fresh and replacement commands.
# PHP snippets are single-quoted to keep their variables in the container.
# shellcheck disable=SC2016
set -Ee -o pipefail
umask 077
trap 'printf "Playground integration failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/octojoom-playground.XXXXXXXX")
run_id=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n' | tr 0123456789 ghijklmnop)
domain="$run_id.localhost"
network="octojoom-pg-$run_id"
ssh_network="octojoom-ssh-$run_id"
proxy="octojoom-traefik-$run_id"
retired_container="retired$run_id"
route_file="octojoom-$run_id.txt"
write_file="octojoom-$run_id.php"
export OCTOJOOM_HOME="$work/home"
sites="$OCTOJOOM_HOME/Docker/joomla/available"
shared_env="$OCTOJOOM_HOME/Docker/joomla/.env"
package="$work/Donor store.zip"
offline_package="$work/Offline donor store.zip"
renamed_package="$work/Renamed donor store.zip"
image=joomla:6.2.0-php8.4-apache
database_image=mariadb:11.4
fpm_image=joomla:6.2.0-php8.4-fpm
repair_image="octojoom-ci-repair:opaque-$run_id"
mysql_image=mysql:8.4
nginx_docroot=store/public
DONOR_PASSWORD=$(openssl rand -hex 18)
DONOR_DB_PASSWORD=$(openssl rand -hex 18)
CONFIRMED_PASSWORD=$(openssl rand -hex 18)
CONFIRMED_PASSWORD+='$literal!'
export DONOR_PASSWORD DONOR_DB_PASSWORD CONFIRMED_PASSWORD
donor() { docker compose -p "pgdonor$run_id" -f "$work/donor.yml" "$@"; }
destination_env() {
  local site="$sites/$1.$domain"
  if [ -f "$site/.env" ]; then printf '%s\n' "$site/.env"
  elif [ -f "$shared_env" ]; then printf '%s\n' "$shared_env"
  else return 1; fi
}
destination() {
  local site="$sites/$1.$domain" env_file
  env_file=$(destination_env "$1") || return 1
  shift
  docker compose --env-file "$env_file" -f "$site/docker-compose.yml" "$@"
}
cleanup() {
  local status=$? sub site
  trap - EXIT INT TERM ERR
  set +e
  for sub in new stopped failed; do
    site="$sites/$sub.$domain"
    if [ "$sub" = new ] && [ "${alignment_in_progress:-false}" = true ]; then
      docker compose -p "$alignment_project" --project-directory "$site" --env-file "$work/pre-alignment-site.env" \
        -f "$work/pre-alignment-compose.yml" down -v --remove-orphans >/dev/null
    elif [ -f "$site/docker-compose.yml" ] && destination_env "$sub" >/dev/null; then
      destination "$sub" down -v --remove-orphans >/dev/null
    fi
  done
  if [ -f "$work/donor.yml" ]; then donor down -v --remove-orphans >/dev/null; fi
  if [ -f "$work/no-listener.json" ]; then
    docker compose -p "pgprobe$run_id" -f "$work/no-listener.json" down -v >/dev/null
  fi
  docker image rm "$repair_image" >/dev/null 2>&1
  docker rm -f "$proxy" "$retired_container" >/dev/null 2>&1
  docker network rm "$network" "$ssh_network" >/dev/null 2>&1
  if ((EUID == 0)); then rm -rf -- "$work"; else sudo -n rm -rf -- "$work"; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The donor's local socket is available to the unmodified Playground exporter.
cat > "$work/donor.yml" <<YAML
services:
  db:
    image: $database_image
    environment:
      MARIADB_RANDOM_ROOT_PASSWORD: 'yes'
      MARIADB_DATABASE: donor
      MARIADB_USER: donor
      MARIADB_PASSWORD: \${DONOR_DB_PASSWORD}
    volumes:
      - socket:/run/mysqld
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 2s
      timeout: 5s
      retries: 60
  web:
    image: $image
    depends_on:
      db:
        condition: service_healthy
    environment:
      JOOMLA_DB_HOST: db
      JOOMLA_DB_NAME: donor
      JOOMLA_DB_USER: donor
      JOOMLA_DB_PASSWORD: \${DONOR_DB_PASSWORD}
      JOOMLA_DB_PREFIX: demo_
      JOOMLA_SITE_NAME: Playground Donor
      JOOMLA_ADMIN_USER: Donor Administrator
      JOOMLA_ADMIN_USERNAME: donoradmin
      JOOMLA_ADMIN_EMAIL: donor@example.test
      JOOMLA_ADMIN_PASSWORD: \${DONOR_PASSWORD}
    volumes:
      - socket:/run/mysqld:ro
volumes:
  socket:
YAML
docker network create "$network" >/dev/null
docker network create "$ssh_network" >/dev/null
docker run -d --name "$proxy" --network "$network" -p 127.0.0.1::80 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro traefik:v3.6 \
  --entrypoints.web.address=:80 --providers.docker=true --providers.docker.exposedbydefault=false \
  --providers.docker.network="$network" --providers.providersThrottleDuration=100ms >/dev/null
proxy_port=$(docker port "$proxy" 80/tcp)
proxy_port=${proxy_port#127.0.0.1:}
donor up -d --wait --wait-timeout 240
for ((i=0; i<90; i++)); do
  if donor exec -T web sh -c 'test -s configuration.php && test ! -d installation && curl -fsS http://127.0.0.1/ >/dev/null' 2>/dev/null; then break; fi
  sleep 2
done
((i < 90)) || { echo 'Donor Joomla installation did not become ready.' >&2; exit 1; }
donor exec -T web php -r '
  require "configuration.php"; $c = new JConfig;
  $db = new mysqli($c->host, $c->user, $c->password, $c->db);
  $db->query("CREATE TABLE demo_fixture_marker (
    value INT NOT NULL, price DECIMAL(7,2), flags BIT(8), payload BLOB, optional_qty INT,
    customer_type ENUM(\"retail\",\"wholesale\"), tags SET(\"a\",\"b\"), model_year YEAR,
    legacy_label VARCHAR(12) CHARACTER SET latin1
  )");
  $db->query("INSERT INTO demo_fixture_marker VALUES
    (4381,-2.50,128,0x00FF31,NULL,\"wholesale\",\"a,b\",2024,CONVERT(0xC3A9 USING utf8mb4))");
  if ($db->query("SELECT HEX(legacy_label) FROM demo_fixture_marker")->fetch_row()[0] !== "E9") exit(1);
  $account = $db->query("SELECT u.id, GROUP_CONCAT(m.group_id ORDER BY m.group_id), SHA2(u.password,256)
    FROM demo_users u JOIN demo_user_usergroup_map m ON m.user_id=u.id
    WHERE u.username=\"donoradmin\" GROUP BY u.id,u.password")->fetch_row();
  if (!$account) exit(2);
  echo implode("\t", $account), "\n";
' > "$work/donor-account"
IFS=$'\t' read -r donor_id donor_groups donor_hash_digest < "$work/donor-account"
export_revision=1dd95451f8a0c3fda51802f8cbf0a1e72d0fb079
curl --fail --silent --show-error --location --retry 3 \
  "https://raw.githubusercontent.com/joomengine/playground/$export_revision/src/export/site.php" -o "$work/export.php"
[ "$(git hash-object "$work/export.php")" = ed47c417a5d69581cfa4ed71d54e891794535379 ]
donor cp "$work/export.php" web:/tmp/fixture-export.php >/dev/null
# Disposable HTTP fixture: write through the proxy and read through the direct
# port to verify that both routes use the same imported website storage.
cat > "$work/proof.php" <<'PHP'
<?php
$marker = __DIR__ . '/tmp/octojoom-write-fixture.txt';
if ($_SERVER['REQUEST_METHOD'] === 'POST' && file_put_contents($marker, 'stored fixture write') === false) {
    http_response_code(500);
    exit;
}
echo is_file($marker) ? file_get_contents($marker) : 'no fixture write';
PHP
chmod 644 "$work/proof.php"
donor cp "$work/proof.php" "web:/var/www/html/$write_file" >/dev/null
donor exec -T web sh -c 'echo "$1" > "$2"' sh "exported-online-$run_id" "$route_file"
export_package() {
  local output="$1" export_dir
  export_dir="/tmp/joomengine-export-$(cat /proc/sys/kernel/random/uuid)"
  donor exec -T web php -d pdo_mysql.default_socket=/run/mysqld/mysqld.sock -r '
  $exportOptions = [
    "operation" => "create", "root" => "/var/www/html", "directory" => $argv[1], "format" => "bundle",
    "playground" => ["schemaVersion" => 1, "configuration" => [
      "admin" => ["username" => getenv("JOOMLA_ADMIN_USERNAME"), "email" => getenv("JOOMLA_ADMIN_EMAIL"),
        "name" => getenv("JOOMLA_ADMIN_USER"), "password" => getenv("JOOMLA_ADMIN_PASSWORD")],
      "phpSettings" => ["memory_limit" => "512M"]
    ]],
    // Only the portable JConfig is redacted here. The exporter connects with
    // the donor application account from its installed configuration.php.
    "database" => ["host" => "localhost", "user" => "", "password" => "", "name" => "donor"]
  ];
  require "/tmp/fixture-export.php";
  ' -- "$export_dir" > "$work/export-receipt"
  sed -n 's/^__JOOMENGINE_RESULT__//p' "$work/export-receipt" | jq -e '
    .ok and .metadata.playground.configuration.admin.username=="donoradmin" and
    (.metadata.playground.contentHash.value | test("^[0-9a-f]{64}$"))' >/dev/null
  donor cp "web:$export_dir/site.zip" "$output" >/dev/null
}
export_package "$package"
donor exec -T web php -d register_argc_argv=1 cli/joomla.php site:down
export_package "$offline_package"
donor exec -T web php -d register_argc_argv=1 cli/joomla.php site:up
# Change the installed website after saving its launch identity. The same
# unmodified exporter still receives the original, now stale, admin settings.
donor exec -T --user 0 web php -r '
  require "configuration.php"; $c = new JConfig;
  $db = new mysqli($c->host, $c->user, $c->password, $c->db);
  $changed = $db->prepare("UPDATE demo_users SET username=\"shopmanager\",password=? WHERE username=\"donoradmin\"");
  $hash = password_hash(bin2hex(random_bytes(24)), PASSWORD_BCRYPT);
  $changed->bind_param("s", $hash);
  $changed->execute();
  if ($changed->affected_rows !== 1 || password_verify(getenv("JOOMLA_ADMIN_PASSWORD"), $hash)) exit(1);
'
donor exec -T web sh -c 'echo "$1" > "$2"' sh "exported-renamed-$run_id" "$route_file"
export_package "$renamed_package"
source_secret=$(donor exec -T web php -r 'require "configuration.php"; echo hash("sha256", (new JConfig)->secret);')
donor down -v >/dev/null

# The Apache destination changes the administrator using protected JSON. The
# Nginx destination retains the donor account and initially remains stopped.
python3 - "$work/request.json" <<'PY'
import json, os, sys
with open(sys.argv[1], "w") as output:
    json.dump({"type":"joomla","task":"playground","options":{
        "site-name":"Imported Shop", "admin-username":"shopmanager", "admin-user":"Shop Manager",
        "admin-email":"shop@example.test", "admin-password":os.environ["CONFIRMED_PASSWORD"],
    }}, output)
PY
deploy() {
  local sub="$1" key="$2" input="$3" bind="$4"; shift 4
  bash "$root/src/octojoom" --type joomla --task playground --action deploy --target new \
    --file "$input" --key "$key" --domain "$domain" --sub-domain "$sub" \
    --image-source joomla \
    --traefik-network "$network" --openssh-network "$ssh_network" --update-hosts false --secure false \
    --persistence "$bind" --db-persistence "$bind" --phpmyadmin false --mailcatcher false \
    --non-interactive --output json "$@" > "$work/result"
}
# Source the same literal .env reader used by the application.
# shellcheck disable=SC1090
source <(awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' "$root/src/octojoom")
check_http() {
  local sub="$1" key="$2" web="$3" attempt
  for ((attempt=0; attempt<20; attempt++)); do
    if destination "$sub" exec -T "joomla$key" curl --silent --max-time 5 --include \
        --header "Host: $sub.$domain" "http://$web/" > "$work/homepage" &&
      awk 'NR==1 {ok=($2==200)} END {exit !ok}' "$work/homepage"; then
      return 0
    fi
    sleep 1
  done
  printf 'The Joomla home page did not return its expected HTTP 200 response.\n' >&2
  return 1
}
check_site() {
  local sub="$1" key="$2" sitename="$3" username="$4" display="$5" email="$6" password="$7"
  local docroot="${8:-/var/www/html}" web="${9:-127.0.0.1}"
  local env_file var expected observed expected_hash_digest='' uid='' gid=''
  env_file=$(destination_env "$sub") || return 1
  migrationReadEnvValue "$env_file" "VDM_${key^^}_PUID" uid || uid=''
  migrationReadEnvValue "$env_file" "VDM_${key^^}_PGID" gid || gid=''
  uid="${uid#\#}"; gid="${gid#\#}"
  [ "$(stat -c %a "$env_file")" = 600 ] || { echo 'Site environment permissions are too broad.' >&2; return 1; }
  # Fresh setup records installation choices. Existing imports change Joomla
  # content and accounts while preserving the operator's original environment.
  if [ "${check_fresh_env:-true}" = true ]; then
    for var in SITE_NAME ADMIN_USERNAME ADMIN_USER ADMIN_EMAIL ADMIN_PASSWORD DB_PREFIX; do
      case "$var" in
        SITE_NAME) expected="$sitename";; ADMIN_USERNAME) expected="$username";; ADMIN_USER) expected="$display";;
        ADMIN_EMAIL) expected="$email";; ADMIN_PASSWORD) expected="$password";; DB_PREFIX) expected=demo_;;
      esac
      migrationReadEnvValue "$env_file" "VDM_${key^^}_JOOMLA_$var" observed
      [ "$observed" = "$expected" ] || { echo "Unexpected effective environment field: $var" >&2; return 1; }
    done
  fi
  # Check the original donor ID, groups and Joomla permissions independently
  # of CLI output. The confirmed password travels through standard input.
  # Joomla API calls may write language caches; use the selected website owner.
  if [ "$password" = "$DONOR_PASSWORD" ]; then expected_hash_digest="$donor_hash_digest"; fi
  printf '%s\n%s' "$expected_hash_digest" "$password" |
    destination "$sub" exec -T --user "${uid:-www-data}:${gid:-www-data}" \
      --workdir "$docroot" "joomla$key" php -d register_argc_argv=1 -r '
    define("_JEXEC", 1); define("JPATH_BASE", getcwd());
    require JPATH_BASE."/includes/defines.php";
    require JPATH_BASE."/includes/framework.php";
    $c = new JConfig;
    if ($c->sitename !== $argv[1] || $c->dbprefix !== "demo_" || hash("sha256",$c->secret) !== $argv[5]) exit(1);
    if ($c->tmp_path !== getcwd()."/tmp" || $c->log_path !== getcwd()."/administrator/logs") exit(4);
    $db = new mysqli(explode(":",$c->host)[0],$c->user,$c->password,$c->db);
    $marker = $db->query("SELECT CAST(value AS CHAR), CAST(price AS CHAR), HEX(flags), HEX(payload),
                                 optional_qty, customer_type, tags, CAST(model_year AS CHAR), HEX(legacy_label)
                            FROM demo_fixture_marker")->fetch_row();
    if ($marker !== ["4381","-2.50","80","00FF31",null,"wholesale","a,b","2024","E9"]) exit(2);
    $st = $db->prepare("SELECT name,email,password,id FROM demo_users WHERE username=?");
    $st->bind_param("s",$argv[2]); $st->execute(); $user=$st->get_result()->fetch_row();
    [$expectedHash, $password] = explode("\n", stream_get_contents(STDIN), 2);
    if (!$user || $user[0] !== $argv[3] || $user[1] !== $argv[4] || !password_verify($password,$user[2])) exit(3);
    if ($expectedHash !== "" && hash("sha256", $user[2]) !== $expectedHash) exit(3);
    if ((string) $user[3] !== $argv[6]) exit(6);
    $_SERVER["HTTP_HOST"] = $argv[8]; $_SERVER["REQUEST_URI"] = "/";
    $container = Joomla\CMS\Factory::getContainer();
    foreach (["session", "JSession", Joomla\CMS\Session\Session::class, Joomla\Session\Session::class,
              Joomla\Session\SessionInterface::class] as $alias) $container->alias($alias, "session.cli");
    Joomla\CMS\Factory::$application = $container->get(Joomla\Console\Application::class);
    $account = $container->get(Joomla\CMS\User\UserFactoryInterface::class)->loadUserById((int) $user[3]);
    $groups = array_values($account->groups);
    sort($groups, SORT_NUMERIC);
    if ($account->block || !$account->authorise("core.login.admin") || implode(",", $groups) !== $argv[7]) exit(7);
    echo "Account verified\n";
  ' -- "$sitename" "$username" "$display" "$email" "$source_secret" "$donor_id" "$donor_groups" "$sub.$domain" > "$work/account-check"
  grep -Fxq 'Account verified' "$work/account-check"
  check_http "$sub" "$key" "$web"
}
first="p$run_id"; second="q$run_id"; failed="r$run_id"
apache_options=(--engine mariadb --database-image "$database_image")
fresh_started=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
deploy new "$first" "$offline_package" true "${apache_options[@]}" --input-json "$work/request.json"
jq -e '.success and .data.enabled == true' "$work/result" >/dev/null
# One-shot PHP import helpers may run, but fresh setup starts the website once.
docker events --since "$fresh_started" --until "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" \
  --filter type=container --filter event=start --format '{{json .}}' > "$work/fresh-starts.jsonl"
jq -se --arg service "joomla$first" '
  [.[] | select(.Actor.Attributes["com.docker.compose.service"]==$service and
    ((.Actor.Attributes["com.docker.compose.oneoff"] // "false") | ascii_downcase)!="true")]
  | length == 1' "$work/fresh-starts.jsonl" >/dev/null
# Check what Docker actually installed on an intentionally offline import.
web="joomla$first"
expected_probe='["CMD","curl","-fsS","--noproxy","*","--request","OPTIONS","--request-target","*","http://127.0.0.1"]'
# Normal enable can return before Docker schedules the first 30-second check.
wait_for_web_probe() {
  local i
  for ((i=0; i<60; i++)); do
    [ "$(docker inspect --format '{{.State.Health.Status}}' "$web")" = starting ] || return 0
    sleep 2
  done
  return 1
}
wait_for_web_probe
docker inspect "$web" | jq -e --argjson probe "$expected_probe" '.[0] |
  .State.Health.Status=="healthy" and .Config.Healthcheck.Test==$probe and
  .Config.Healthcheck.Interval==30000000000 and .Config.Healthcheck.Timeout==5000000000 and
  .Config.Healthcheck.Retries==5' >/dev/null
[ "$(docker exec "$web" curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1/)" = 503 ]
docker exec "$web" php -d register_argc_argv=1 cli/joomla.php site:up
check_site new "$first" 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD"
legacy_test='["CMD", "curl", "-f", "http://localhost/"]'
site_compose="$sites/new.$domain/docker-compose.yml"
enabled_compose="$OCTOJOOM_HOME/Docker/joomla/enabled/new.$domain/docker-compose.yml"
site_env="$sites/new.$domain/.env"
alignment_project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$web")
alignment_db_id=$(destination new ps -q "mariadb$first")
cp -p "$site_env" "$work/pre-alignment-site.env"
cp -p "$site_compose" "$work/pre-alignment-compose.yml"
if [ -f "$shared_env" ]; then cp -p "$shared_env" "$work/pre-alignment-shared.env"; fi
alignment_in_progress=true
cp -p "$site_env" "$shared_env"
printf '\nCOMPOSE_PROJECT_NAME=%s\nFIXTURE_IMAGE=%s\nFIXTURE_REGION=Africa/Windhoek\n' "$alignment_project" "$image" >> "$shared_env"
rm "$site_env"
cp -p "$shared_env" "$work/alignment-shared.env"

publish_fixture_compose() {
  cat "$1" > "$site_compose"
  if [ -f "$enabled_compose" ] && ! [ "$enabled_compose" -ef "$site_compose" ]; then cp "$site_compose" "$enabled_compose"; fi
}
# Keep the running project's real identity in the shared env. Losing that env
# would resolve a different project even when the same directory is used.
printf 'name: other%s\n' "$run_id" > "$work/named-compose.yml"
cat "$site_compose" >> "$work/named-compose.yml"
joomlaServiceProperty "$site_compose" "$web" labels > "$work/site-labels"
printf '      - "octojoom.fixture.region=${FIXTURE_REGION:?missing region}"\n' >> "$work/site-labels"
joomlaSetServiceProperty "$work/named-compose.yml" "$work/literal-image.yml" "$web" labels "$work/site-labels"
[ "$(siteReadServiceScalar "$work/literal-image.yml" "$web" image)" = "$image" ]
align=(bash "$root/src/octojoom" --type joomla --task align --container "new.$domain" --action apply --non-interactive)
assert_probe_only_change() {
  cmp "$1" "$site_compose"
  cmp "$1" "$enabled_compose"
  cmp "$work/alignment-shared.env" "$shared_env"
  [ ! -e "$site_env" ]
  [ "$(destination new ps -q "mariadb$first")" = "$alignment_db_id" ]
}
publish_legacy_probe() {
  awk -v legacy="$legacy_test" '/^      test: .*"--request-target"/ { $0="      test: " legacy; changed++ }
    { print } END { if (changed!=1) exit 1 }' "$1" > "$work/legacy-compose.yml"
  publish_fixture_compose "$work/legacy-compose.yml"
}

# A generated literal image and a stopped web container must stay that way.
publish_legacy_probe "$work/literal-image.yml"
destination new stop "$web"
destination new up --no-start --no-deps --force-recreate "$web"
docker inspect "$web" | jq -e --argjson test "$legacy_test" '.[0] |
  (.State.Running|not) and .Config.Healthcheck.Test==$test' >/dev/null
"${align[@]}"
assert_probe_only_change "$work/literal-image.yml"
docker inspect "$web" | jq -e --argjson probe "$expected_probe" '.[0] |
  (.State.Running|not) and .Config.Healthcheck.Test==$probe' >/dev/null

# Repeat on the running site with an operator-owned image expression.
siteReplaceServiceScalar "$work/literal-image.yml" "$work/operator-image.yml" "$web" image '${FIXTURE_IMAGE:?missing image}'
publish_legacy_probe "$work/operator-image.yml"
destination new up -d --no-deps --wait --wait-timeout 240 "$web" >/dev/null
check_site new "$first" 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD"

# Apply the documented update while Joomla is offline. Only the web container changes.
legacy_id=$(destination new ps -q "$web")
alignment_image=$(docker inspect --format '{{.Image}} {{.Config.Image}}' "$legacy_id")
docker inspect "$legacy_id" | jq -e --argjson test "$legacy_test" '.[0].Config.Healthcheck.Test==$test' >/dev/null
docker exec "$web" php -d register_argc_argv=1 cli/joomla.php site:down
for ((i=0; i<10; i++)); do
  legacy_exit=0
  docker exec "$web" curl -fs -o /dev/null http://localhost/ || legacy_exit=$?
  if ((legacy_exit == 22)); then break; fi
  sleep 1
done
[ "$legacy_exit" = 22 ]
alignment_model() {
  destination new config --format json | jq -cS --arg web "$web" 'del(.services[$web].healthcheck.test)'
}
alignment_model > "$work/before-alignment.json"
"${align[@]}"
assert_probe_only_change "$work/operator-image.yml"
alignment_model > "$work/after-alignment.json"
cmp "$work/before-alignment.json" "$work/after-alignment.json"
[ "$(destination new ps -q "$web")" != "$legacy_id" ]
[ "$(docker inspect --format '{{.Image}} {{.Config.Image}}' "$web")" = "$alignment_image" ]
wait_for_web_probe
docker inspect "$web" | jq -e --argjson probe "$expected_probe" --arg project "$alignment_project" '.[0] |
  .Config.Healthcheck.Test==$probe and .State.Health.Status=="healthy" and
  .Config.Labels["octojoom.fixture.region"]=="Africa/Windhoek" and
  .Config.Labels["com.docker.compose.project"]==$project' >/dev/null
offline_identity=$(docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' "$web")
offline_start=$SECONDS
first_health_end=$(docker inspect "$web" | jq -er '.[0].State.Health.Log[-1].End')
"${align[@]}"
assert_probe_only_change "$work/operator-image.yml"
[ "$(docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' "$web")" = "$offline_identity" ]
# Return the fixture files to the layout used by the independent import tests.
publish_fixture_compose "$work/pre-alignment-compose.yml"
cp -p "$work/pre-alignment-site.env" "$site_env"
if [ -f "$work/pre-alignment-shared.env" ]; then mv "$work/pre-alignment-shared.env" "$shared_env"; else rm "$shared_env"; fi
alignment_in_progress=false
# Run the same image and effective probe without Apache listening. Docker must
# mark this still-running container unhealthy using the production retry policy.
destination new config --format json | jq --arg web "$web" '.services[$web] |
  {services:{unavailable:{image,healthcheck,network_mode:"none",entrypoint:["sleep","infinity"]}}}' > "$work/no-listener.json"
no_listener=(docker compose -p "pgprobe$run_id" -f "$work/no-listener.json")
"${no_listener[@]}" up -d
probe_container=$("${no_listener[@]}" ps -q unavailable)

deploy stopped "$second" "$package" false --enable false --image-tag "${fpm_image#*:}" \
  --engine mysql --database-image "$mysql_image" --webserver nginx --docroot "$nginx_docroot"
jq -e --arg image "$fpm_image" '.success and .data.enabled == false and .data.image == $image' "$work/result" >/dev/null
[ ! -e "$OCTOJOOM_HOME/Docker/joomla/enabled/stopped.$domain" ]
[ -z "$(destination stopped ps -q --status running)" ]
destination stopped config --format json | jq -e --arg key "$second" --arg db "$mysql_image" \
  --arg root "/var/www/html/$nginx_docroot" --arg nginx_conf "$sites/stopped.$domain/nginx.conf" '
    .services["mariadb"+$key].image == $db and
    .services["joomla"+$key].working_dir == $root and
    any(.services["nginx"+$key].volumes[];
        .source == $nginx_conf and .target == "/etc/nginx/conf.d/default.conf" and .read_only)
  ' >/dev/null
destination stopped up -d --wait --wait-timeout 240 >/dev/null
check_site stopped "$second" 'Playground Donor' donoradmin 'Donor Administrator' donor@example.test "$DONOR_PASSWORD" \
  "/var/www/html/$nginx_docroot" "nginx$second"

# A valid older-format bundle with a deliberately unsuccessful final SQL
# statement reaches database import. Both existing fresh sites must survive.
python3 - "$package" "$work/failing.zip" <<'PY'
import json, sys, zipfile
statement = "SELECT nonexistent_column FROM demo_fixture_marker"
with zipfile.ZipFile(sys.argv[1]) as src, zipfile.ZipFile(sys.argv[2],"w") as out:
    suffix = (statement + ";\n").encode()
    for entry in src.infolist():
        data = src.read(entry)
        if entry.filename == "export.json":
            meta = json.loads(data)
            meta["playground"].pop("contentHash", None)
            meta["database"]["bytes"] += len(suffix)
            data = json.dumps(meta).encode()
        elif entry.filename == "database.sql":
            data += suffix
        elif entry.filename == "database.ndjson":
            data += (json.dumps(statement) + "\n").encode()
        out.writestr(entry,data)
PY
if deploy failed "$failed" "$work/failing.zip" false "${apache_options[@]}" 2>"$work/failure.log"; then
  echo 'Invalid SQL was accepted.' >&2; exit 1
fi
jq -e '.success==false' "$work/result" >/dev/null
grep -Fq 'The Playground database import failed.' "$work/failure.log" || { echo 'Failure did not reach the native SQL import.' >&2; exit 1; }
[ ! -e "$sites/failed.$domain" ]
[ ! -e "$OCTOJOOM_HOME/Projects/$failed" ]
if docker container inspect "joomla$failed" >/dev/null 2>&1 || docker container inspect "mariadb$failed" >/dev/null 2>&1; then
  echo 'Failed fresh deployment left a destination container behind.' >&2; exit 1
fi
[ -z "$(docker ps -aq --filter "label=com.docker.compose.service=mariadb$failed")" ]
[ -z "$(docker volume ls -q --filter 'label=com.octoleo.octojoom.playground' --filter "name=$failed")" ]
echo 'Fresh Playground deployment passed for Apache/MariaDB and Nginx/PHP-FPM/MySQL, including SQL values and administrator accounts.'

check_fresh_env=false
# Reproduce a long-lived installation whose Apache site uses the shared ENV.
# The stopped/FPM site keeps its private ENV throughout the remaining tests.
cp "$sites/new.$domain/.env" "$shared_env"
chmod 600 "$shared_env"
cat >> "$shared_env" <<'ENV'

# Keep unrelated site settings and comments exactly as the operator wrote them.
VDM_RETIRED_DB="retired_fixture"
VDM_RETIRED_NOTE='literal $value # preserved'
ENV
rm "$sites/new.$domain/.env"
retired_dir="$sites/retired.$domain"
malformed_dir="$sites/malformed.$domain"
mkdir "$retired_dir" "$malformed_dir"
# The retired site's private ENV lacks the variable needed to resolve its bind.
printf 'VDM_RETIRED_DB=retired_fixture\n' > "$retired_dir/.env"
cat > "$retired_dir/docker-compose.yml" <<YAML
version: '3.8'
services:
  retired:
    image: nginx:alpine
    container_name: $retired_container
    environment:
      RETIRED_DATABASE: \${VDM_RETIRED_DB}
      OPTIONAL_UNRELATED_SETTING: \${VDM_RETIRED_ABSENT}
    volumes:
      - "\${VDM_PROJECT_PATH}/retired-$run_id:/fixture:ro"
YAML
printf 'services: [\n' > "$malformed_dir/docker-compose.yml"
cp -R "$retired_dir" "$work/retired-before"
cp -R "$malformed_dir" "$work/malformed-before"
# A real exited container and the running proxy must retain their lifecycles.
docker run --name "$retired_container" --network none \
  --mount "type=bind,src=$retired_dir,dst=/fixture,readonly" traefik:v3.6 version >/dev/null
unrelated_container_state() {
  docker inspect --format '{{.Id}} {{.State.Status}} {{.State.StartedAt}} {{.State.FinishedAt}} {{.RestartCount}}' \
    "$proxy" "$retired_container"
}
unrelated_container_state > "$work/unrelated-containers.before"
sed "/^VDM_${first^^}_/d" "$shared_env" > "$work/shared-unrelated.env"
assert_shared_environment() {
  [ "$(destination_env new)" = "$shared_env" ]
  [ ! -e "$sites/new.$domain/.env" ]
  sed "/^VDM_${first^^}_/d" "$shared_env" > "$work/shared-unrelated.current"
  cmp "$work/shared-unrelated.env" "$work/shared-unrelated.current"
}
assert_unrelated_sites() {
  diff -r "$work/retired-before" "$retired_dir"
  diff -r "$work/malformed-before" "$malformed_dir"
  [ ! -e "$OCTOJOOM_HOME/Docker/joomla/enabled/retired.$domain" ]
  [ ! -e "$OCTOJOOM_HOME/Docker/joomla/enabled/malformed.$domain" ]
  unrelated_container_state > "$work/unrelated-containers.current"
  cmp "$work/unrelated-containers.before" "$work/unrelated-containers.current"
}
assert_clean_replacement_log() {
  if grep -Eq 'the attribute .version. is obsolete|variable is not set|Defaulting to a blank string' "$1"; then
    echo 'Replacement emitted an obsolete Compose version or missing-variable warning.' >&2
    return 1
  fi
}
assert_shared_environment

# Mark the disposable destination so replacement can prove that only its
# files, database and application secret changed. A custom hosting property
# and mail host in its original JConfig must carry forward to the new site.
replacement_state() {
  local sub="$1" key="$2" mode="$3" docroot="${4:-/var/www/html}"
  destination "$sub" exec -T --user 0 --workdir "$docroot" "joomla$key" php -d register_argc_argv=1 -r '
    require "configuration.php"; $c = new JConfig();
    $db = new mysqli(explode(":",$c->host)[0],$c->user,$c->password,$c->db);
    $mode=$argv[1]; $marker=".octojoom-ci-previous"; $oldSecret="previous-" . $argv[2];
    $literalTable="ci_previous_`\\line\nbreak";
    if ($mode === "seed") {
        $db->query("CREATE TABLE ci_previous_data (id INTEGER PRIMARY KEY)");
        $db->query("INSERT INTO ci_previous_data VALUES (2026)");
        $db->query("SET SESSION sql_mode=\"NO_BACKSLASH_ESCAPES\"");
        $db->query("CREATE TABLE `".str_replace("`","``",$literalTable)."` (id INTEGER)");
        $db->query("CREATE VIEW ci_previous_view AS SELECT id FROM ci_previous_data");
        $db->query("CREATE PROCEDURE ci_previous_procedure() SELECT 1");
        $db->query("CREATE EVENT ci_previous_event ON SCHEDULE EVERY 1 DAY DISABLE DO UPDATE ci_previous_data SET id=id");
        if (file_put_contents($marker,"original website\n") === false) exit(1);
        $raw=file_get_contents("configuration.php");
        foreach (["secret"=>$oldSecret,"smtphost"=>"mail.fixture.invalid"] as $field=>$value) {
            $raw=preg_replace_callback("/^([ \\t]*)public\\s+\\$".$field."\\s*=.*?;[ \\t]*$/m",
                static fn($m) => ($field === "secret" ? $m[1]."public \$ciTargetPolicy = true;\n" : "")
                    .$m[1]."public $".$field." = ".var_export($value,true).";", $raw,1,$n);
            if ($n !== 1) exit(2);
        }
        if (file_put_contents("configuration.php",$raw) === false) exit(3);
        exit;
    }
    $old = $mode === "original";
    if ($mode === "recovered") {
        if ($c->smtphost !== "localhost" || isset($c->ciTargetPolicy)) exit(4);
    } elseif ($c->smtphost !== "mail.fixture.invalid" || ($c->ciTargetPolicy ?? null) !== true) {
        exit(4);
    }
    if (($c->secret === $oldSecret) !== $old || is_file($marker) !== $old) exit(4);
    $table=(bool)$db->query("SHOW TABLES LIKE \"ci_previous_data\"")->num_rows;
    if ($table !== $old || ($old && (int)$db->query("SELECT id FROM ci_previous_data")->fetch_row()[0] !== 2026)) exit(5);
    foreach ([
        ["TABLES", "TABLE_SCHEMA", "TABLE_NAME", $literalTable],
        ["TABLES", "TABLE_SCHEMA", "TABLE_NAME", "ci_previous_view"],
        ["ROUTINES", "ROUTINE_SCHEMA", "ROUTINE_NAME", "ci_previous_procedure"],
        ["EVENTS", "EVENT_SCHEMA", "EVENT_NAME", "ci_previous_event"],
    ] as [$catalog, $schema, $field, $name]) {
        $query=$db->prepare("SELECT COUNT(*) FROM information_schema.$catalog WHERE $schema=DATABASE() AND $field=?");
        $query->bind_param("s", $name); $query->execute();
        if ((bool)$query->get_result()->fetch_row()[0] !== $old) exit(6);
    }
  ' -- "$mode" "$sub"
}
replace_site() {
  local sub="$1" input="$2"; shift 2
  bash "$root/src/octojoom" --type joomla --task playground --action deploy --target current \
    --container "$sub.$domain" --file "$input" --confirm yes --non-interactive --output json "$@" > "$work/result"
}
publish_fixture_port() {
  local sub="$1" service="$2" compose="$sites/$1.$domain/docker-compose.yml" enabled next port
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  next="$work/ports-$sub.yml"; enabled="$OCTOJOOM_HOME/Docker/joomla/enabled/$sub.$domain/docker-compose.yml"
  printf '    ports:\n      - "127.0.0.1:%s:80"\n' "$port" > "$work/ports.property"
  joomlaSetServiceProperty "$compose" "$next" "$service" ports "$work/ports.property"
  cat "$next" > "$compose"
  if [ -f "$enabled" ] && ! [ "$enabled" -ef "$compose" ]; then cp "$compose" "$enabled"; fi
  destination "$sub" up -d --no-deps --wait --wait-timeout 240 "$service" >&2
  [ "$(destination "$sub" port "$service" 80)" = "127.0.0.1:$port" ] || return 1
  printf '%s\n' "$port"
}
require_routed_text() {
  local sub="$1" port="$2" path="$3" expected="$4" method="${5:-GET}" response attempt
  for ((attempt=0; attempt<40; attempt++)); do
    if response=$(curl --noproxy '*' -fsS --max-time 2 -X "$method" --header "Host: $sub.$domain" \
      "http://127.0.0.1:$port/$path" 2>/dev/null) && [ "$response" = "$expected" ]; then return 0; fi
    sleep 1
  done
  printf 'The fixture HTTP %s did not return the expected marker for %s.\n' "$method" "$sub" >&2
  return 1
}
report_admin_failure() {
  local sub="$1" response="$2" service
  service=$(destination "$sub" config --services | sed -n '/^joomla/p') || return 0
  destination "$sub" logs --no-color --tail 80 "$service" > "$work/admin-container.log" 2>&1 || true
  # Collect redactions separately so diagnostics never expose site credentials.
  destination "$sub" exec -T --user 0 "$service" php -r '
    require "configuration.php"; $c=new JConfig(); $redact=[]; $logs=[];
    foreach (get_object_vars($c) as $key=>$value) {
        if (is_string($value) && $value !== "" && preg_match("/password|secret|token/i",$key)) $redact[]=$value;
    }
    foreach (glob($c->log_path."/*") ?: [] as $path) {
        if (is_file($path) && preg_match("/\.(php|log)$/",$path)) $logs[basename($path)]=substr(file_get_contents($path),-8192);
    }
    echo json_encode(["redact"=>$redact,"logs"=>$logs,"session_handler"=>$c->session_handler,
        "secret_bytes"=>strlen($c->secret),"log_writable"=>is_writable($c->log_path)],JSON_INVALID_UTF8_SUBSTITUTE);
  ' > "$work/admin-diagnostics.json" 2>/dev/null || : > "$work/admin-diagnostics.json"
  python3 - "$response" "$work/admin-diagnostics.json" "$work/admin-container.log" <<'PY' >&2
from html.parser import HTMLParser
from pathlib import Path
import json, os, re, sys
class Text(HTMLParser):
    def __init__(self):
        super().__init__(); self.parts=[]; self.hidden=0
    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"): self.hidden += 1
    def handle_endtag(self, tag):
        if tag in ("script", "style"): self.hidden = max(0, self.hidden - 1)
    def handle_data(self, data):
        if not self.hidden: self.parts.append(data)
raw=Path(sys.argv[2]).read_text()
metadata=json.loads(raw) if raw else {}
secrets=metadata.pop("redact", []) + [os.environ.get(key, "") for key in
    ("DONOR_PASSWORD", "DONOR_DB_PASSWORD", "CONFIRMED_PASSWORD")]
def emit(label, value):
    for secret in sorted(filter(None, secrets), key=len, reverse=True): value=value.replace(secret, "[redacted]")
    print(label + ": " + value[:8192])
page=Text(); page.feed(Path(sys.argv[1]).read_text(errors="replace"))
emit("Administrator response", re.sub(r"\s+", " ", " ".join(page.parts)).strip())
if metadata:
    emit("Joomla diagnostics", json.dumps(metadata, ensure_ascii=False))
    emit("Application log", Path(sys.argv[3]).read_text(errors="replace"))
PY
}
check_admin_login() {
  local sub="$1" username="$2" password="$3" token http_status url="http://$1.$domain:$proxy_port"
  local -a request=(curl --noproxy '*' --fail-with-body --silent --show-error --max-time 30
    --resolve "$sub.$domain:$proxy_port:127.0.0.1")
  # Traefik publishes the route after Docker reports a healthy service.
  # Wait for this export's public marker before sending the login request.
  require_routed_text "$sub" "$proxy_port" "$route_file" "$4" || return 1
  rm -f "$work/cookies"
  if ! http_status=$("${request[@]}" -c "$work/cookies" -o "$work/login.html" -w '%{http_code}' "$url/administrator/"); then
    printf 'Administrator login form returned HTTP %s.\n' "$http_status" >&2
    report_admin_failure "$sub" "$work/login.html"
    return 1
  fi
  token=$(sed -nE 's/.*name="([a-f0-9]{32})"[[:space:]]+value="1".*/\1/p' "$work/login.html" | head -n 1)
  if [ -z "$token" ]; then report_admin_failure "$sub" "$work/login.html"; return 1; fi
  # Keep the password out of process arguments and ordinary test output.
  printf '%s' "$password" > "$work/login-password"
  if ! http_status=$("${request[@]}" --location -b "$work/cookies" -c "$work/cookies" \
    --data-urlencode "username=$username" --data-urlencode "passwd@$work/login-password" \
    --data-urlencode 'option=com_login' --data-urlencode 'task=login' --data-urlencode "$token=1" \
    -o "$work/admin.html" -w '%{http_code}' "$url/administrator/index.php"); then
    rm -f "$work/login-password"
    printf 'Administrator login returned HTTP %s.\n' "$http_status" >&2
    report_admin_failure "$sub" "$work/admin.html"
    return 1
  fi
  rm -f "$work/login-password"
  if ! grep -Eq 'task=logout|task=login.logout|com_cpanel' "$work/admin.html"; then
    report_admin_failure "$sub" "$work/admin.html"
    return 1
  fi
}
# Snapshot actual persistent-resource identities, including mount directory
# inodes. A successful import must replace contents without moving storage.
storage_identity() {
  local sub="$1" key="$2" app db
  app=$(destination "$sub" ps -aq "joomla$key")
  db=$(destination "$sub" ps -aq "mariadb$key")
  docker inspect "$app" "$db" | jq -cS '[.[] | {
    service:.Config.Labels["com.docker.compose.service"],
    project:.Config.Labels["com.docker.compose.project"],
    mounts:([.Mounts[] | {Type,Name,Source,Destination,RW}] | sort_by(.Destination))
  }] | sort_by(.service)'
  if [ "$sub" = new ]; then
    stat -c '%n %i' "$OCTOJOOM_HOME/Projects/$key/joomla" "$OCTOJOOM_HOME/Projects/$key/db"
  fi
}
resource_inventory() {
  docker volume ls -q | sort
  docker network ls --format '{{.Name}}' | sort
  find "$OCTOJOOM_HOME/Projects" -mindepth 1 -maxdepth 2 -type d -print | sort
  find "$sites" -mindepth 1 -maxdepth 2 -type d -print | sort
}
other_database() {
  destination new exec -T "mariadb$first" sh -c \
    'exec mariadb --user=root --password="$MARIADB_ROOT_PASSWORD" --batch --skip-column-names'
}
without_backup=(--pre-backup no --confirm-no-backup yes)
# The native offline form and both authenticated sessions must work through Traefik
# beyond the five-check failure window.
remaining=$((180 - (SECONDS - offline_start)))
if ((remaining > 0)); then sleep "$remaining"; fi
docker inspect "$web" | jq -e --arg first "$first_health_end" '.[0].State | .Running and
  .Health.Status=="healthy" and .Health.FailingStreak==0 and (.Health.Log | length)==5 and
  all(.Health.Log[]; .ExitCode==0 and .End>$first)' >/dev/null
docker inspect "$probe_container" | jq -e '.[0].State | .Running and .Health.Status=="unhealthy" and
  .Health.FailingStreak>=5 and all(.Health.Log[]; .ExitCode==7)' >/dev/null
[ "$(docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' "$web")" = "$offline_identity" ]
site_url="http://new.$domain:$proxy_port"
frontend=(curl --silent --show-error --noproxy '*' --max-time 20 --resolve "new.$domain:$proxy_port:127.0.0.1")
guest_code=$("${frontend[@]}" -c "$work/offline-cookies" -o "$work/offline.html" -w '%{http_code}' "$site_url/")
[ "$guest_code" = 503 ]
grep -Fq 'class="offline-card"' "$work/offline.html"
token=$(sed -nE 's/.*name="([a-f0-9]{32})"[[:space:]]+value="1".*/\1/p' "$work/offline.html" | head -n 1)
[ -n "$token" ]
printf '%s' "$CONFIRMED_PASSWORD" | "${frontend[@]}" --fail --location -b "$work/offline-cookies" -c "$work/offline-cookies" \
  --data-urlencode 'username=shopmanager' --data-urlencode 'password@-' --data-urlencode 'option=com_users' \
  --data-urlencode 'task=user.login' --data-urlencode "$token=1" "$site_url/index.php" > /dev/null
[ "$("${frontend[@]}" -b "$work/offline-cookies" -o "$work/auth-home.html" -w '%{http_code}' "$site_url/")" = 200 ]
grep -Fq 'Imported Shop' "$work/auth-home.html"
check_admin_login new shopmanager "$CONFIRMED_PASSWORD" "exported-online-$run_id"
docker exec "$web" php -d register_argc_argv=1 cli/joomla.php site:up
check_site new "$first" 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD"
[ "$("${frontend[@]}" -o /dev/null -w '%{http_code}' "$site_url/")" = 200 ]
[ "$(docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' "$web")" = "$offline_identity" ]
printf 'Offline Joomla retained healthy probes for %ss, anonymous HTTP 503 and both logins. Guest HTTP 200 returned without a restart.\n' "$((SECONDS - offline_start))"
replacement_state new "$first" seed
destination new exec -T --user 0 "joomla$first" sh -c 'echo "$1" > "$2"' sh "previous-new-$run_id" "/var/www/html/$route_file"
apache_port=$(publish_fixture_port new "joomla$first")
require_routed_text new "$apache_port" "$route_file" "previous-new-$run_id"
check_admin_login new shopmanager "$CONFIRMED_PASSWORD" "previous-new-$run_id"
printf '\nprecision = 15\n' >> "$OCTOJOOM_HOME/Projects/$first/php.ini"
# A custom probe belongs to the operator. Import must leave it unchanged.
original_health=$(destination new config --format json | jq -cS --arg app "joomla$first" '.services[$app].healthcheck')
jq -e --argjson probe "$expected_probe" '.test==$probe' <<< "$original_health" >/dev/null
printf '    healthcheck:\n      test: ["CMD", "curl", "--silent", "--fail", "http://localhost/"]\n      interval: 17s\n      timeout: 4s\n      retries: 7\n' > "$work/custom-health.property"
joomlaSetServiceProperty "$sites/new.$domain/docker-compose.yml" "$work/custom-health.yml" \
  "joomla$first" healthcheck "$work/custom-health.property"
awk '/^[[:space:]]+(- )?JOOMLA_DB_PREFIX[:=]/ { $0=$0 " # Keep the existing site prefix binding"; matched++ }
  { print } END { if (matched!=1) exit 1 }' "$work/custom-health.yml" > "$sites/new.$domain/docker-compose.yml"
destination new up -d --no-deps --wait --wait-timeout 240 "joomla$first" >/dev/null
other_database <<'SQL'
CREATE DATABASE octojoom_other_fixture;
CREATE TABLE octojoom_other_fixture.keep_me (value VARCHAR(60));
INSERT INTO octojoom_other_fixture.keep_me VALUES ('another database survives');
SQL
mkdir "$work/before"
cp "$(destination_env new)" "$sites/new.$domain/docker-compose.yml" "$work/before/"
ln "$sites/new.$domain/docker-compose.yml" "$work/before/compose-inode"
storage_identity new "$first" > "$work/before/bind-storage"
resource_inventory > "$work/before/resources"
original_db=$(destination new ps -q "mariadb$first")
neighbor_ids=$(destination stopped ps --status running -q | sort)
assert_preserved() {
  assert_shared_environment
  cmp "$(destination_env new)" "$work/before/.env"
  assert_unrelated_sites
  cmp "$sites/new.$domain/docker-compose.yml" "$work/before/docker-compose.yml"
  [ "$sites/new.$domain/docker-compose.yml" -ef "$work/before/compose-inode" ]
  storage_identity new "$first" > "$work/current-storage"
  cmp "$work/before/bind-storage" "$work/current-storage"
  resource_inventory > "$work/current-resources"
  cmp "$work/before/resources" "$work/current-resources"
  [ "$(destination new ps -q "mariadb$first")" = "$original_db" ]
  [ "$(destination stopped ps --status running -q | sort)" = "$neighbor_ids" ]
  [ "$(other_database <<< 'SELECT value FROM octojoom_other_fixture.keep_me;')" = 'another database survives' ]
}
assert_original() {
  cmp "$(destination_env new)" "$work/before/.env"
  assert_preserved
  check_http new "$first" 127.0.0.1
  replacement_state new "$first" original
}
# An unconfirmed opt-out and a failed requested backup must not write any data.
if replace_site new "$renamed_package" --pre-backup no --input-json "$work/request.json"; then
  echo 'One refusal bypassed the backup waiver.' >&2; exit 1
fi
jq -e '.success==false' "$work/result" >/dev/null
assert_original
touch "$work/blocked-backup"
writeEnvVariable "$(destination_env new)" "VDM_${first^^}_BACKUP_PATH=$work/blocked-backup" true
cp -p "$(destination_env new)" "$work/before/blocked.env"
if replace_site new "$renamed_package" --input-json "$work/request.json"; then
  echo 'A failed required backup allowed replacement.' >&2; exit 1
fi
jq -e '.success==false and .data.stage=="backup" and .data.backup==null and
  .data.destructive_started==false' "$work/result" >/dev/null
cmp "$(destination_env new)" "$work/before/blocked.env"
cp -p "$work/before/.env" "$(destination_env new)"
assert_original

# Replace ZIP A with ZIP B in the same bind mounts and selected database.
replace_site new "$renamed_package" --input-json "$work/request.json" 2> "$work/running-replacement.log"
jq -e '.success and .data.target=="current" and .data.status=="deployed" and .data.running' "$work/result" >/dev/null
assert_clean_replacement_log "$work/running-replacement.log"
backup=$(jq -er '.data.backup' "$work/result")
[ -f "$backup" ] && [ -f "$backup.sha256" ]
bash "$root/src/octojoom" --type joomla --task backup --action verify --container "new.$domain" \
  --file "$backup" --non-interactive --output json > "$work/verified"
jq -e '.success and .data.verified and .data.scope=="full"' "$work/verified" >/dev/null
python3 - "$backup" "$work/before/docker-compose.yml" "$first" <<'PY'
from pathlib import Path, PurePosixPath
import sys, tarfile
with tarfile.open(sys.argv[1], "r:*") as archive:
    members = {str(PurePosixPath(m.name)): m for m in archive}
    def content(name):
        return archive.extractfile(members[name]).read()
    assert content("project/joomla/.octojoom-ci-previous") == b"original website\n"
    assert b"ci_previous_data" in content("project/database.sql")
    assert content("compose/docker-compose.yml") == Path(sys.argv[2]).read_bytes()
    environment = content("compose/.env")
    assert ("VDM_" + sys.argv[3].upper() + "_DB=").encode() in environment
    assert b"VDM_RETIRED_NOTE" not in environment
PY
[ "$(find "${backup%/*}" -maxdepth 1 -name '*.sha256' | wc -l)" -eq 1 ]
assert_preserved
check_site new "$first" 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD"
check_admin_login new shopmanager "$CONFIRMED_PASSWORD" "exported-renamed-$run_id"
replacement_state new "$first" replaced
[ "$(destination new exec -T "joomla$first" php -r 'echo ini_get("precision");')" = 15 ]
require_routed_text new "$apache_port" "$route_file" "exported-renamed-$run_id"
require_routed_text new "$proxy_port" "$write_file" 'stored fixture write' POST
require_routed_text new "$apache_port" "$write_file" 'stored fixture write'

# Explicit opt-out reuses the same storage without another archive or copy.
backup_listing=$(find "${backup%/*}" -maxdepth 1 -type f -print | sort)
replace_site new "$package" "${without_backup[@]}" 2> "$work/running-no-backup.log"
jq -e '.success and .data.backup==null and .data.running' "$work/result" >/dev/null
assert_clean_replacement_log "$work/running-no-backup.log"
[ "$backup_listing" = "$(find "${backup%/*}" -maxdepth 1 -type f -print | sort)" ]
assert_preserved
check_site new "$first" 'Playground Donor' donoradmin 'Donor Administrator' donor@example.test "$DONOR_PASSWORD"
check_admin_login new donoradmin "$DONOR_PASSWORD" "exported-online-$run_id"
replacement_state new "$first" replaced
require_routed_text new "$apache_port" "$route_file" "exported-online-$run_id"

# A stopped Nginx/MySQL site imports into its existing named volumes and stays
# stopped. Only the selected database and one-shot PHP helpers may start.
replacement_state stopped "$second" seed "/var/www/html/$nginx_docroot"
nginx_port=$(publish_fixture_port stopped "nginx$second")
storage_identity stopped "$second" > "$work/before/named-storage"
# The selected app runs a locally tagged image with an opaque repository and tag.
# Its service and mount declarations supply the information required for repair.
docker tag "$fpm_image" "$repair_image"
siteReplaceServiceScalar "$sites/stopped.$domain/docker-compose.yml" "$work/repair-compose.yml" \
  "joomla$second" image "$repair_image"
cp "$work/repair-compose.yml" "$sites/stopped.$domain/docker-compose.yml"
cp "$sites/stopped.$domain/docker-compose.yml" "$work/before/nginx-compose.yml"
private_env=$(destination_env stopped)
sed "/^VDM_${second^^}_WEBSERVER=/d" "$private_env" > "$work/custom-private.env"
printf 'CUSTOM_DOMAIN=example.test\n' >> "$work/custom-private.env"
cat "$work/custom-private.env" > "$private_env"
destination stopped exec -T --user 0 --workdir /var/www/html "joomla$second" sh -ceu '
  mkdir store/companion
  printf "%s\n" "private companion content" > store/companion/keep.txt
  chmod 640 store/companion/keep.txt
  chown 1234:1235 store/companion/keep.txt
  mv store real-store
  ln -s real-store store
'
destination stopped stop >/dev/null
if replace_site stopped "$renamed_package" "${without_backup[@]}" --input-json "$work/request.json" 2> "$work/symlinked-root.log"; then
  echo 'Replacement followed a symlinked document-root ancestor.' >&2; exit 1
fi
jq -e '.success==false and .data.destructive_started==false' "$work/result" >/dev/null
[ -z "$(destination stopped ps -q --status running)" ]
destination stopped run --rm -T --no-deps --user 0 --workdir /var/www/html --entrypoint sh "joomla$second" -ceu '
  test -L store
  test "$(cat real-store/public/.octojoom-ci-previous)" = "original website"
  rm store
  mv real-store store
  rm store/public/configuration.php
'
new_neighbor_ids=$(destination new ps --status running -q | sort)
started_after=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
replace_site stopped "$renamed_package" "${without_backup[@]}" --input-json "$work/request.json" 2> "$work/stopped-replacement.log"
jq -e '.success and .data.target=="current" and .data.backup==null and .data.running==false' "$work/result" >/dev/null
assert_clean_replacement_log "$work/stopped-replacement.log"
assert_unrelated_sites
[ "$(destination_env stopped)" = "$private_env" ]
cmp "$work/custom-private.env" "$private_env"
[ ! -e "$OCTOJOOM_HOME/Docker/joomla/enabled/stopped.$domain" ]
[ -z "$(destination stopped ps -q --status running)" ]
cmp "$sites/stopped.$domain/docker-compose.yml" "$work/before/nginx-compose.yml"
resource_inventory > "$work/current-resources"
cmp "$work/before/resources" "$work/current-resources"
[ "$backup_listing" = "$(find "${backup%/*}" -maxdepth 1 -type f -print | sort)" ]
docker events --since "$started_after" --until "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" \
  --filter type=container --filter event=start --format '{{json .}}' > "$work/stopped-starts.jsonl"
jq -se --arg app "joomla$second" --arg http "nginx$second" '
  [.[] | select((.Actor.Attributes["com.docker.compose.service"]==$app or
    .Actor.Attributes["com.docker.compose.service"]==$http) and
    ((.Actor.Attributes["com.docker.compose.oneoff"] // "false") | ascii_downcase)!="true")]
  | length == 0' "$work/stopped-starts.jsonl" >/dev/null
for port in "$proxy_port" "$nginx_port"; do
  if curl --noproxy '*' -fsS --max-time 2 --header "Host: stopped.$domain" \
      "http://127.0.0.1:$port/$route_file" >/dev/null 2>&1; then
    echo 'The stopped site was reachable after import.' >&2; exit 1
  fi
done
destination stopped up -d --wait --wait-timeout 240 >/dev/null
destination stopped exec -T --user 0 --workdir /var/www/html "joomla$second" sh -ceu '
  test "$(cat store/companion/keep.txt)" = "private companion content"
  test "$(stat -c %a:%u:%g store/companion/keep.txt)" = "640:1234:1235"
'
storage_identity stopped "$second" > "$work/current-storage"
cmp "$work/before/named-storage" "$work/current-storage"
check_site stopped "$second" 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD" \
  "/var/www/html/$nginx_docroot" "nginx$second"
check_admin_login stopped shopmanager "$CONFIRMED_PASSWORD" "exported-renamed-$run_id"
replacement_state stopped "$second" recovered "/var/www/html/$nginx_docroot"
[ "$(destination new ps --status running -q | sort)" = "$new_neighbor_ids" ]
require_routed_text stopped "$nginx_port" "$route_file" "exported-renamed-$run_id"
assert_shared_environment

# A native SQL failure after overwrite starts is a failed import. The running
# website remains stopped; an explicit no-backup waiver supplies no old copy.
failure_neighbor_ids=$(destination stopped ps --status running -q | sort)
if replace_site new "$work/failing.zip" "${without_backup[@]}" 2> "$work/failed-in-place.log"; then
  echo 'An in-place SQL failure was reported as successful.' >&2; exit 1
fi
jq -e '.success==false and .data.destructive_started==true and .data.backup==null' "$work/result" >/dev/null
grep -Fq 'The Playground database import failed.' "$work/failed-in-place.log"
assert_unrelated_sites
[ -z "$(destination new ps -q --status running "joomla$first")" ]
[ "$backup_listing" = "$(find "${backup%/*}" -maxdepth 1 -type f -print | sort)" ]
resource_inventory > "$work/current-resources"
cmp "$work/before/resources" "$work/current-resources"
[ "$(other_database <<< 'SELECT value FROM octojoom_other_fixture.keep_me;')" = 'another database survives' ]
[ "$(destination stopped ps --status running -q | sort)" = "$failure_neighbor_ids" ]
# A valid import into the same stopped destination completes without enabling
# it. The operator then starts it through the ordinary Compose path.
replace_site new "$renamed_package" "${without_backup[@]}" --input-json "$work/request.json"
jq -e '.success and .data.running==false and .data.backup==null' "$work/result" >/dev/null
destination new up -d --wait --wait-timeout 240 >/dev/null
check_site new "$first" 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD"
check_admin_login new shopmanager "$CONFIRMED_PASSWORD" "exported-renamed-$run_id"
storage_identity new "$first" > "$work/current-storage"
cmp "$work/before/bind-storage" "$work/current-storage"
assert_shared_environment
assert_unrelated_sites
echo 'Playground in-place import passed: unchanged bind/named storage, selected database, routing and custom settings; shared/private ENV; old-only files/tables removed; administrator login; verified backup, opt-out, failed-backup refusal and truthful import failure.'
