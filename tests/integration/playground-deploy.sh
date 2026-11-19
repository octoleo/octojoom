#!/usr/bin/env bash
# Generate a private complete Playground export from an installed official
# Joomla donor and deploy it through Octojoom's public fresh-site command.
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
image=joomla:6.2.0-php8.4-apache
database_image=mariadb:11.4
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
  $db->query("CREATE TABLE demo_fixture_marker (value INT NOT NULL)");
  $db->query("INSERT INTO demo_fixture_marker VALUES (4381)");
'
export_revision=1dd95451f8a0c3fda51802f8cbf0a1e72d0fb079
curl --fail --silent --show-error --location --retry 3 \
  "https://raw.githubusercontent.com/joomengine/playground/$export_revision/src/export/site.php" -o "$work/export.php"
[ "$(git hash-object "$work/export.php")" = ed47c417a5d69581cfa4ed71d54e891794535379 ]
donor cp "$work/export.php" web:/tmp/fixture-export.php >/dev/null
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
sed -n 's/^__JOOMENGINE_RESULT__//p' "$work/export-receipt" | jq -e '.ok==true' >/dev/null
donor cp "web:$export_dir/site.zip" "$package" >/dev/null
source_secret=$(donor exec -T web php -r 'require "configuration.php"; echo hash("sha256", (new JConfig)->secret);')
donor down -v >/dev/null

# Protected JSON overrides the administrator for "new"; "stopped" retains
# the exported administrator and settings with explicit --enable false.
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
    --image-source joomla --image-tag "${image#*:}" --engine mariadb --database-image "$database_image" \
    --traefik-network "$network" --openssh-network "$ssh_network" --update-hosts false --secure false \
    --persistence "$bind" --db-persistence "$bind" --phpmyadmin false --mailcatcher false \
    --non-interactive --output json "$@" > "$work/result"
}
# Source the same literal .env reader used by the application.
# shellcheck disable=SC1090
source <(awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' "$root/src/octojoom")
check_site() {
  local sub="$1" key="$2" sitename="$3" username="$4" display="$5" email="$6" password="$7"
  local env_file="$sites/$sub.$domain/.env" var expected observed
  [ "$(stat -c %a "$env_file")" = 600 ] || { echo 'Site environment permissions are too broad.' >&2; return 1; }
  for var in SITE_NAME ADMIN_USERNAME ADMIN_USER ADMIN_EMAIL ADMIN_PASSWORD DB_PREFIX; do
    case "$var" in
      SITE_NAME) expected="$sitename";; ADMIN_USERNAME) expected="$username";; ADMIN_USER) expected="$display";;
      ADMIN_EMAIL) expected="$email";; ADMIN_PASSWORD) expected="$password";; DB_PREFIX) expected=demo_;;
    esac
    migrationReadEnvValue "$env_file" "VDM_${key^^}_JOOMLA_$var" observed
    [ "$observed" = "$expected" ] || { echo "Unexpected per-site environment field: $var" >&2; return 1; }
  done
  # A read-only SQL lookup checks the persisted account and test marker.
  # Pass the fixture password over stdin; no interactive sign-in or Joomla UI.
  printf '%s' "$password" | destination "$sub" exec -T "joomla$key" php -r '
    require "configuration.php"; $c = new JConfig;
    if ($c->sitename !== $argv[1] || $c->dbprefix !== "demo_" || hash("sha256",$c->secret) !== $argv[5]) exit(1);
    $db = new mysqli(explode(":",$c->host)[0],$c->user,$c->password,$c->db);
    if ((int)$db->query("SELECT value FROM demo_fixture_marker")->fetch_row()[0] !== 4381) exit(2);
    $st = $db->prepare("SELECT name,email,password FROM demo_users WHERE username=?");
    $st->bind_param("s",$argv[2]); $st->execute(); $user=$st->get_result()->fetch_row();
    if (!$user || $user[0] !== $argv[3] || $user[1] !== $argv[4] || !password_verify(stream_get_contents(STDIN),$user[2])) exit(3);
  ' -- "$sitename" "$username" "$display" "$email" "$source_secret"
  destination "$sub" exec -T "joomla$key" curl -fsS --max-time 10 http://127.0.0.1/ >/dev/null
}
first="p$run_id"; second="q$run_id"; failed="r$run_id"
deploy new "$first" "$package" true --input-json "$work/request.json"
jq -e '.success and .data.enabled == true' "$work/result" >/dev/null
check_site new "$first" 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD"
destination new up -d --force-recreate --wait --wait-timeout 240 >/dev/null
check_site new "$first" 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD"

deploy stopped "$second" "$package" false --enable false
jq -e '.success and .data.enabled == false' "$work/result" >/dev/null
[ ! -e "$OCTOJOOM_HOME/Docker/joomla/enabled/stopped.$domain" ]
[ -z "$(destination stopped ps -q --status running)" ]
destination stopped up -d --wait --wait-timeout 240 >/dev/null
check_site stopped "$second" 'Playground Donor' donoradmin 'Donor Administrator' donor@example.test "$DONOR_PASSWORD"

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
if deploy failed "$failed" "$work/failing.zip" false 2>"$work/failure.log"; then
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
check_site new "$first" 'Imported Shop' shopmanager 'Shop Manager' shop@example.test "$CONFIRMED_PASSWORD"
echo 'Fresh Playground deployment passed with existing and updated settings, both storage types, recreation, and failed-import cleanup.'
