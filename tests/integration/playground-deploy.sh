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
export OCTOJOOM_HOME="$work/home"
sites="$OCTOJOOM_HOME/Docker/joomla/available"
package="$work/Donor store.zip"
offline_package="$work/Offline donor store.zip"
offline_message='The donor shop is closed for inventory.'
image=joomla:6.2.0-php8.4-apache
database_image=mariadb:11.4
fpm_image=joomla:6.2.0-php8.4-fpm
mysql_image=mysql:8.4
nginx_docroot=store/public
DONOR_PASSWORD=$(openssl rand -hex 18)
DONOR_DB_PASSWORD=$(openssl rand -hex 18)
CONFIRMED_PASSWORD=$(openssl rand -hex 18)
CONFIRMED_PASSWORD+='$literal!'
export DONOR_PASSWORD DONOR_DB_PASSWORD CONFIRMED_PASSWORD
donor() { docker compose -p "pgdonor$run_id" -f "$work/donor.yml" "$@"; }
destination() {
  local site="$sites/$1.$domain"; shift
  docker compose --env-file "$site/.env" -f "$site/docker-compose.yml" "$@"
}
cleanup() {
  local status=$? sub site
  trap - EXIT INT TERM ERR
  set +e
  for sub in new stopped failed; do
    site="$sites/$sub.$domain"
    if [ -f "$site/.env" ] && [ -f "$site/docker-compose.yml" ]; then
      destination "$sub" down -v --remove-orphans >/dev/null
    fi
  done
  if [ -f "$work/donor.yml" ]; then donor down -v --remove-orphans >/dev/null; fi
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
  $raw = file_get_contents("configuration.php");
  foreach (["offline"=>true, "display_offline_message"=>1, "offline_message"=>$argv[1]] as $key=>$value) {
      $raw = preg_replace_callback("/^(\\h*public\\s+\\$".$key."\\s*=).*?;\\h*$/ms",
          static fn($m) => $m[1]." ".var_export($value, true).";", $raw, 1, $count);
      if ($count !== 1) exit(2);
  }
  if (file_put_contents("configuration.php", $raw) === false) exit(3);
' -- "$offline_message"
export_package "$offline_package"
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
  local sub="$1" key="$2" mode="$3" web="$4" attempt expected=200
  [ "$mode" != offline ] || expected=503
  for ((attempt=0; attempt<20; attempt++)); do
    if destination "$sub" exec -T "joomla$key" curl --silent --max-time 5 --include \
        --header "Host: $sub.$domain" "http://$web/" > "$work/homepage" &&
      awk -v expected="$expected" 'NR==1 {ok=($2==expected)} END {exit !ok}' "$work/homepage" &&
      { [ "$mode" != offline ] || grep -Fq -- "$offline_message" "$work/homepage"; }; then
      return 0
    fi
    sleep 1
  done
  printf 'The %s Joomla home page did not return its expected HTTP %s response.\n' "$mode" "$expected" >&2
  return 1
}
check_site() {
  local sub="$1" key="$2" mode="$3" sitename="$4" username="$5" display="$6" email="$7" password="$8"
  local docroot="${9:-/var/www/html}" web="${10:-127.0.0.1}"
  local env_file="$sites/$sub.$domain/.env" var expected observed expected_hash_digest=''
  [ "$(stat -c %a "$env_file")" = 600 ] || { echo 'Site environment permissions are too broad.' >&2; return 1; }
  for var in SITE_NAME ADMIN_USERNAME ADMIN_USER ADMIN_EMAIL ADMIN_PASSWORD DB_PREFIX; do
    case "$var" in
      SITE_NAME) expected="$sitename";; ADMIN_USERNAME) expected="$username";; ADMIN_USER) expected="$display";;
      ADMIN_EMAIL) expected="$email";; ADMIN_PASSWORD) expected="$password";; DB_PREFIX) expected=demo_;;
    esac
    migrationReadEnvValue "$env_file" "VDM_${key^^}_JOOMLA_$var" observed
    [ "$observed" = "$expected" ] || { echo "Unexpected per-site environment field: $var" >&2; return 1; }
  done
  # Check the original donor ID, groups and Joomla permissions independently
  # of CLI output. The confirmed password travels through standard input.
  if [ "$password" = "$DONOR_PASSWORD" ]; then expected_hash_digest="$donor_hash_digest"; fi
  printf '%s\n%s' "$expected_hash_digest" "$password" |
    destination "$sub" exec -T --workdir "$docroot" "joomla$key" php -d register_argc_argv=1 -r '
    define("_JEXEC", 1); define("JPATH_BASE", getcwd());
    require JPATH_BASE."/includes/defines.php";
    require JPATH_BASE."/includes/framework.php";
    $c = new JConfig;
    if ($c->sitename !== $argv[1] || $c->dbprefix !== "demo_" || hash("sha256",$c->secret) !== $argv[5]) exit(1);
    if ($c->tmp_path !== getcwd()."/tmp" || $c->log_path !== getcwd()."/administrator/logs") exit(4);
    if ((bool) $c->offline !== ($argv[8] === "offline")) exit(5);
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
    $_SERVER["HTTP_HOST"] = $argv[9]; $_SERVER["REQUEST_URI"] = "/";
    $container = Joomla\CMS\Factory::getContainer();
    foreach (["session", "JSession", Joomla\CMS\Session\Session::class, Joomla\Session\Session::class,
              Joomla\Session\SessionInterface::class] as $alias) $container->alias($alias, "session.cli");
    Joomla\CMS\Factory::$application = $container->get(Joomla\Console\Application::class);
    $account = $container->get(Joomla\CMS\User\UserFactoryInterface::class)->loadUserById((int) $user[3]);
    $groups = array_values($account->groups);
    sort($groups, SORT_NUMERIC);
    if ($account->block || !$account->authorise("core.login.admin") || implode(",", $groups) !== $argv[7]) exit(7);
    echo "Account verified\n";
  ' -- "$sitename" "$username" "$display" "$email" "$source_secret" "$donor_id" "$donor_groups" "$mode" "$sub.$domain" > "$work/account-check"
  grep -Fxq 'Account verified' "$work/account-check"
  check_http "$sub" "$key" "$mode" "$web"
}
first="p$run_id"; second="q$run_id"; failed="r$run_id"
apache_options=(--engine mariadb --database-image "$database_image")
deploy new "$first" "$offline_package" true "${apache_options[@]}" --input-json "$work/request.json"
jq -e '.success and .data.enabled == true' "$work/result" >/dev/null
check_site new "$first" offline 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD"
destination new up -d --force-recreate --wait --wait-timeout 240 >/dev/null
check_site new "$first" offline 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD"

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
check_site stopped "$second" online 'Playground Donor' donoradmin 'Donor Administrator' donor@example.test "$DONOR_PASSWORD" \
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
grep -q 'database sql failed' "$work/failure.log" || { echo 'Failure did not reach the native SQL import.' >&2; exit 1; }
[ ! -e "$sites/failed.$domain" ]
[ ! -e "$OCTOJOOM_HOME/Projects/$failed" ]
if docker container inspect "joomla$failed" >/dev/null 2>&1 || docker container inspect "mariadb$failed" >/dev/null 2>&1; then
  echo 'Failed fresh deployment left a destination container behind.' >&2; exit 1
fi
[ -z "$(docker ps -aq --filter "label=com.docker.compose.service=mariadb$failed")" ]
[ -z "$(docker volume ls -q --filter 'label=com.octoleo.octojoom.playground' --filter "name=$failed")" ]
check_site new "$first" offline 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD"
echo 'Fresh Playground deployment preserved the renamed offline Apache/MariaDB site and the online Nginx/PHP-FPM/MySQL site.'

# Mark the disposable destination so replacement can prove that only its
# files, database and application secret changed. A custom hosting property
# and mail host in its original JConfig must carry forward to the new site.
replacement_state() {
  local sub="$1" key="$2" mode="$3" docroot="${4:-/var/www/html}"
  destination "$sub" exec -T --user 0 --workdir "$docroot" "joomla$key" php -d register_argc_argv=1 -r '
    require "configuration.php"; $c = new JConfig();
    $db = new mysqli(explode(":",$c->host)[0],$c->user,$c->password,$c->db);
    $mode=$argv[1]; $marker=".octojoom-ci-previous"; $oldSecret="previous-" . $argv[2];
    if ($mode === "seed") {
        $db->query("CREATE TABLE ci_previous_data (id INTEGER PRIMARY KEY)");
        $db->query("INSERT INTO ci_previous_data VALUES (2026)");
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
    if ($c->smtphost !== "mail.fixture.invalid" || ($c->ciTargetPolicy ?? null) !== true
        || ($c->secret === $oldSecret) !== $old || is_file($marker) !== $old) exit(4);
    $table=(bool)$db->query("SHOW TABLES LIKE \"ci_previous_data\"")->num_rows;
    if ($table !== $old || ($old && (int)$db->query("SELECT id FROM ci_previous_data")->fetch_row()[0] !== 2026)) exit(5);
  ' -- "$mode" "$sub"
}
replace_site() {
  local sub="$1" input="$2"; shift 2
  bash "$root/src/octojoom" --type joomla --task playground --action deploy --target current \
    --container "$sub.$domain" --file "$input" --confirm yes --non-interactive --output json "$@" > "$work/result"
}
without_backup=(--pre-backup no --confirm-no-backup yes)
replacement_state new "$first" seed
mkdir "$work/before"
cp "$sites/new.$domain/.env" "$sites/new.$domain/docker-compose.yml" "$work/before/"
printf '\nprecision = 15\n' >> "$OCTOJOOM_HOME/Projects/$first/php.ini"
neighbor_ids=$(destination stopped ps --status running -q | sort)
assert_original() {
  cmp "$sites/new.$domain/.env" "$work/before/.env"
  cmp "$sites/new.$domain/docker-compose.yml" "$work/before/docker-compose.yml"
  check_http new "$first" offline 127.0.0.1
  replacement_state new "$first" original
  [ "$(destination stopped ps --status running -q | sort)" = "$neighbor_ids" ]
}

# Neither a single backup refusal nor a failed SQL import may publish data.
if replace_site new "$package" --pre-backup no; then echo 'One refusal bypassed the backup confirmation.' >&2; exit 1; fi
jq -e '.success==false' "$work/result" >/dev/null
assert_original
if replace_site new "$work/failing.zip" "${without_backup[@]}" 2>"$work/bad-replacement.log"; then
  echo 'Replacement accepted a failing SQL import.' >&2; exit 1
fi
jq -e '.success==false' "$work/result" >/dev/null
if ! grep -q 'database sql failed' "$work/bad-replacement.log"; then
  jq -r '"Unexpected replacement failure at stage " + (.data.stage // "unknown")' "$work/result" >&2
  # Only the fixed operational labels are public; configuration and SQL stay private.
  grep -E '^Replacement candidate failed while [a-zA-Z ]+\.$' "$work/bad-replacement.log" >&2 || :
  for diagnostic in 'unsupported custom service configuration' 'unsupported extra mount in the isolated site' \
    'unexpected website mount access' 'unsupported data mount' 'unexpected bind source' 'unexpected volume source' \
    'Cannot isolate the configured website, database, or HTTP companion.' \
    'Could not reconcile the source Joomla secret and destination site settings.' \
    'Could not reconcile the destination Joomla database configuration.'; do
    if grep -Fq -- "$diagnostic" "$work/bad-replacement.log"; then printf '%s\n' "$diagnostic" >&2; fi
  done
  echo 'Replacement did not reach the native import.' >&2; exit 1
fi
assert_original

# Make the selected backup destination unusable. The default backup policy
# must stop publication even after the replacement candidate is ready.
touch "$work/blocked-backup"
writeEnvVariable "$sites/new.$domain/.env" "VDM_${first^^}_BACKUP_PATH=$work/blocked-backup" true
cp -p "$sites/new.$domain/.env" "$work/before/blocked.env"
if replace_site new "$package"; then echo 'A failed required backup allowed replacement.' >&2; exit 1; fi
jq -e '.success==false and .data.stage=="backup" and .data.backup==null' "$work/result" >/dev/null
cmp "$sites/new.$domain/.env" "$work/before/blocked.env"
cp -p "$work/before/.env" "$sites/new.$domain/.env"
assert_original

# Fail one public Compose activation. The unpublished deployment and all
# rollback commands continue to use Docker itself. There is no product hook.
mkdir "$work/one-shot"
export FIXTURE_DOCKER FIXTURE_COMPOSE="$sites/new.$domain/docker-compose.yml" FIXTURE_FAULT="$work/activation-failed"
FIXTURE_DOCKER=$(command -v docker)
cat > "$work/one-shot/docker" <<'SHIM'
#!/usr/bin/env bash
selected=false; up=false; recreate=false
for argument in "$@"; do
  case "$argument" in "$FIXTURE_COMPOSE") selected=true;; up) up=true;; --force-recreate) recreate=true;; esac
done
if "$selected" && "$up" && "$recreate" && [ ! -e "$FIXTURE_FAULT" ]; then
  : > "$FIXTURE_FAULT"
  exit 23
fi
exec "$FIXTURE_DOCKER" "$@"
SHIM
chmod 700 "$work/one-shot/docker"
if PATH="$work/one-shot:$PATH" replace_site new "$package" "${without_backup[@]}"; then
  echo 'A failed public activation was reported as successful.' >&2; exit 1
fi
[ -f "$FIXTURE_FAULT" ]
jq -e '.success==false' "$work/result" >/dev/null
assert_original

# Default-on backup captures the old website and SQL. Replacement restarts
# the already enabled site and upgrades a previous Octojoom Apache healthcheck.
new_compose="$sites/new.$domain/docker-compose.yml"
enabled_compose="$OCTOJOOM_HOME/Docker/joomla/enabled/new.$domain/docker-compose.yml"
apache_health() {
  destination new config --format json | jq -ce --arg app "joomla$first" '.services[$app].healthcheck.test'
}
managed_health=$(apache_health)
cat > "$work/legacy-health.yml" <<'YAML'
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 5s
      retries: 5
YAML
joomlaSetServiceProperty "$new_compose" "$work/legacy-compose.yml" "joomla$first" healthcheck "$work/legacy-health.yml"
cat "$work/legacy-compose.yml" > "$new_compose"
if ! [ "$enabled_compose" -ef "$new_compose" ]; then cp -- "$new_compose" "$enabled_compose"; fi
[ "$(apache_health)" = '["CMD","curl","-f","http://localhost/"]' ]
[ "$(apache_health)" != "$managed_health" ]
old_web=$(destination new ps -q "joomla$first")
old_db=$(destination new ps -q "mariadb$first")
replace_site new "$package"
[ "$(apache_health)" = "$managed_health" ]
backup=$(jq -er '.data | select(.target=="current" and .status=="deployed" and .running==true) | .backup' "$work/result")
[ -f "$backup" ]
[ -f "$backup.sha256" ]
bash "$root/src/octojoom" --type joomla --task backup --action verify --container "new.$domain" \
  --file "$backup" --non-interactive --output json > "$work/verified"
jq -e '.success and .data.verified and .data.scope=="full"' "$work/verified" >/dev/null
python3 - "$backup" <<'PY'
from pathlib import PurePosixPath
import sys, tarfile
with tarfile.open(sys.argv[1], "r:*") as archive:
    members = {str(PurePosixPath(m.name)):m for m in archive}
    assert archive.extractfile(members["project/joomla/.octojoom-ci-previous"]).read() == b"original website\n"
    assert b"ci_previous_data" in archive.extractfile(members["project/database.sql"]).read()
PY
[ -n "$old_web" ]
[ -n "$old_db" ]
[ "$(destination new ps -q "joomla$first")" != "$old_web" ]
[ "$(destination new ps -q "mariadb$first")" != "$old_db" ]
[ -e "$OCTOJOOM_HOME/Docker/joomla/enabled/new.$domain" ]
[ "$(destination stopped ps --status running -q | sort)" = "$neighbor_ids" ]
check_site new "$first" online 'Playground Donor' donoradmin 'Donor Administrator' donor@example.test "$DONOR_PASSWORD"
replacement_state new "$first" replaced
[ "$(destination new exec -T "joomla$first" php -r 'echo ini_get("precision");')" = 15 ]

# Replace the named-volume site from a deliberately stopped, disabled state.
# A successful opt-out must leave only the active volume set and prior backup.
replacement_state stopped "$second" seed "/var/www/html/$nginx_docroot"
named_mounts() {
  local service="$1" target="$2"
  destination stopped config --format json | jq -er --arg service "$service" --arg target "$target" '
    . as $model | .services[$service].volumes[] | select(.target==$target and .type=="volume") |
    $model.volumes[.source].name'
}
old_web_volume=$(named_mounts "joomla$second" /var/www/html)
old_db_volume=$(named_mounts "mariadb$second" /var/lib/mysql)
destination stopped down >/dev/null
new_neighbor_ids=$(destination new ps --status running -q | sort)
backup_listing=$(find "${backup%/*}" -maxdepth 1 -name '*.sha256' -print | sort)
python3 - "$work/request.json" "$work/replace-request.json" <<'PY'
import json, secrets, sys
with open(sys.argv[1]) as source:
    request = json.load(source)
request["options"].update({
    "source-admin-username": "shopmanager", "admin-username": "replacedmanager",
    "db-name": "pg_replaced", "db-user": "pg_replacer",
    "db-password": secrets.token_hex(18) + "'\"$literal!",
})
with open(sys.argv[2], "w") as output:
    json.dump(request, output)
PY
started_after=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
replace_site stopped "$offline_package" "${without_backup[@]}" --input-json "$work/replace-request.json"
jq -e '.success and .data.target=="current" and .data.backup==null and .data.running==false' "$work/result" >/dev/null
# Docker's event log also includes containers removed when returning to the
# stopped state. Capture it before the manual persistence check starts them.
docker events --since "$started_after" --until "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" \
  --filter type=container --filter event=start --format '{{index .Actor.Attributes "name"}}' > "$work/started-containers"
grep -Fxq -- "joomla$second" "$work/started-containers"
grep -Fxq -- "mariadb$second" "$work/started-containers"
[ "$backup_listing" = "$(find "${backup%/*}" -maxdepth 1 -name '*.sha256' -print | sort)" ]
[ ! -e "$OCTOJOOM_HOME/Docker/joomla/enabled/stopped.$domain" ]
[ -z "$(destination stopped ps -q --status running)" ]
active_web_volume=$(named_mounts "joomla$second" /var/www/html)
active_db_volume=$(named_mounts "mariadb$second" /var/lib/mysql)
[ "$active_web_volume" != "$active_db_volume" ]
docker volume inspect "$active_web_volume" "$active_db_volume" >/dev/null
for volume in "$old_web_volume" "$old_db_volume"; do
  if [ "$volume" = "$active_web_volume" ] || [ "$volume" = "$active_db_volume" ]; then
    echo 'Replacement reused original named storage.' >&2; exit 1
  fi
  if docker volume inspect "$volume" >/dev/null 2>&1; then
    echo 'Replacement retained old named storage after the explicit backup opt-out.' >&2; exit 1
  fi
done
destination stopped up -d --wait --wait-timeout 240 >/dev/null
check_site stopped "$second" offline 'Imported Shop' replacedmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD" \
  "/var/www/html/$nginx_docroot" "nginx$second"
replacement_state stopped "$second" replaced "/var/www/html/$nginx_docroot"
# Read the protected request locally and pass it to PHP over stdin so the
# changed database credentials never appear in subprocess arguments or logs.
for setting in DB:db-name DB_USER:db-user DB_PASS:db-password; do
  desired=$(jq -er --arg key "${setting#*:}" '.options[$key]' "$work/replace-request.json")
  migrationReadEnvValue "$sites/stopped.$domain/.env" "VDM_${second^^}_${setting%:*}" observed
  [ "$observed" = "$desired" ]
done
destination stopped exec -T --workdir "/var/www/html/$nginx_docroot" "joomla$second" php -r '
  require "configuration.php"; $c = new JConfig();
  $values = json_decode(stream_get_contents(STDIN),true,512,JSON_THROW_ON_ERROR)["options"];
  if ($c->db !== $values["db-name"] || $c->user !== $values["db-user"] || $c->password !== $values["db-password"]) exit(1);
  $connection = new mysqli(explode(":",$c->host)[0],$c->user,$c->password,$c->db);
  [$name,$account] = $connection->query("SELECT DATABASE(),CURRENT_USER()")->fetch_row();
  if ($name !== $c->db || explode("@",$account)[0] !== $c->user) exit(2);
' < "$work/replace-request.json"
[ "$(destination new ps --status running -q | sort)" = "$new_neighbor_ids" ]
echo 'Existing-site replacement passed for backup, opt-out, SQL failure, rollback, preserved administrator, offline page and restart.'
