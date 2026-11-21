"""Write a deterministic synthetic Playground export for inspection and fresh setup."""

import hashlib
import json
from pathlib import Path
import stat
import sys
import warnings
import zipfile


def write_fixture(destination, variant):
    manifest = "site/administrator/manifests/files/joomla.xml"
    files = {
        "site/configuration.php": b"<?php class JConfig { public $secret = 'private-fixture-key'; }",
        "site/index.php": b"<?php // Fixture site",
        "site/administrator/index.php": b"<?php // Fixture administration",
        manifest: b'<extension type="file"><name>files_joomla</name><version>6.2.0</version></extension>',
        "site/libraries/vendor/autoload.php": b"<?php // Fixture autoloader",
        "site/components/com_example/index.html": b"Component fixture",
        "site/media/example/index.html": b"Media fixture",
    }
    if variant == "minimum-php":
        files[manifest] = files[manifest].replace(b"</extension>", b"<php_minimum>8.3.0</php_minimum></extension>")
    if variant == "fresh":
        files["site/configuration.php"] = b"""<?php
class JConfig {
    public $host = 'localhost';
    public $dbtype = 'mysqli';
    public $db = 'joomla';
    public $user = 'root';
    public $password = 'private-fixture-old-db';
    public $dbprefix = 'demo_';
    public $secret = 'private-fixture-key';
    public $sitename = 'Fixture Shop';
    public $tmp_path = __DIR__ . '/tmp';
    public $log_path = __DIR__ . '/administrator/logs';
    public $live_site = 'https://playground.example.test';
}
"""
    if variant == "path-alias":
        files["site/media/preview.txt"] = b"First website asset"
        files["site/media/Preview.txt"] = b"Second website asset"
    sql = b"CREATE TABLE demo_items (id INTEGER);\n"
    statements = json.dumps(sql.decode().rstrip(";\n")).encode() + b"\n"
    if variant == "mysql-values":
        native_statements = [
            "CREATE TABLE `demo_items` (\n  `bytes` varbinary(16),\n  `qty` int,\n"
            "  `bits` bit(8),\n  `price` decimal(7,2),\n  `note` varchar(120) CHARACTER SET latin1,\n"
            "  `settings` json,\n  `shape` geometry\n"
            ") COMMENT='Preserve text including X''30'' and semicolons ; here'",
            "/* Preserve this SQL example: INSERT INTO `demo_items` (`qty`) VALUES (X'30') */",
            "SET @example = 'Keep the text X''31''; and X''32'''",
            "INSERT INTO `demo_items` (`qty`,`price`,`bytes`,`bits`,`note`,`settings`,`shape`) VALUES "
            "(X'30',X'2D322E3530',X'00FF',X'80',X'436166C3A9',X'7B7D',NULL),"
            "(X'3130',NULL,X'30',X'00',X'',NULL,ST_GeomFromWKB(X'010100000000000000000000000000000000000000',4326))",
            # The exporter reads large text cells in chunks using CAST(column AS BINARY).
            # This time the last byte of Café arrives in the column's original latin1.
            "SET @__joomengine_export_0 = X'436166'",
            "SET @__joomengine_export_0 = CONCAT(@__joomengine_export_0,X'E9')",
            "SET @__joomengine_export_1 = X'7B226C6162656C223A22C3A9227D'",
            "INSERT INTO `demo_items` (`note`,`settings`) VALUES (@__joomengine_export_0,@__joomengine_export_1)",
        ]
        sql = (
            "-- Joomla portable database export\n"
            "-- Import into an empty database selected by your database client.\n"
            "-- Browser login sessions are intentionally excluded.\n"
            + "".join(statement + ";\n" for statement in native_statements)
        ).encode()
        statements = b"".join(json.dumps(statement).encode() + b"\n" for statement in native_statements)
    payload = {
        **files,
        "database.sql": sql,
        "database.ndjson": statements,
    }
    if variant == "missing-sql":
        del payload["database.sql"]
    elif variant == "empty-sql":
        payload["database.sql"] = b""
    elif variant == "missing-manifest":
        del payload[manifest]
    elif variant == "missing-admin-index":
        del payload["site/administrator/index.php"]
    elif variant == "missing-autoloader":
        del payload["site/libraries/vendor/autoload.php"]
    elif variant == "installer":
        payload["site/installation/index.php"] = b"<?php // Installer stub"
    elif variant == "parent-segment":
        payload["site/media/../extra.txt"] = b"Fixture text"
    elif variant == "symlink":
        payload["site/media/alias.html"] = b"example/index.html"

    # The exporter hashes sorted UTF-8 path, uncompressed size and body-digest
    # records. Neither export.json nor the deployment notes are payload records.
    digest = hashlib.sha256()
    for name, body in sorted(payload.items()):
        path = name.encode()
        digest.update(b"%d:%s:%d:%s\n" % (
            len(path), path, len(body), hashlib.sha256(body).hexdigest().encode()
        ))
    config = {
        "schemaVersion": 1,
        "configuration": {
            "siteName": "Fixture Shop",
            "phpVersion": "8.4",
            "admin": {
                "username": "fixture-admin", "name": "private-fixture-name",
                "email": "private-fixture@example.test", "password": "private-fixture-password",
            },
        },
        "contentHash": {
            "algorithm": "sha256",
            "format": "joomengine-site-payload-v1",
            "value": digest.hexdigest(),
        },
    }
    if variant == "fresh":
        config["configuration"]["phpSettings"] = {
            "memory_limit": "512M", "max_execution_time": "60", "max_input_time": "60",
            "max_input_vars": "10000", "upload_max_filesize": "128M", "post_max_size": "160M",
        }
    website_files = [data for name, data in payload.items() if name.startswith("site/")]
    metadata = {
        "format": "joomengine-playground-export",
        "schemaVersion": 1,
        "archiveLayout": {"files": "site/", "database": "database.sql"},
        "siteName": "Fixture Shop",
        "joomlaVersion": "6.2.0",
        "phpVersion": "8.4.27",
        "playground": config,
        "files": {"count": len(website_files), "bytes": sum(map(len, website_files))},
        "database": {
            "name": "joomla", "tablePrefix": "demo_", "tables": ["demo_items"],
            "views": [], "triggers": [], "rows": 0, "bytes": len(sql),
            "format": "mysql", "statements": "database.ndjson",
        },
    }
    if variant == "mysql-values":
        metadata["database"]["rows"] = 3
    if variant == "legacy":
        del config["contentHash"]
    elif variant == "wrong-hash":
        config["contentHash"]["value"] = "f" * 64
    elif variant == "version-mismatch":
        metadata["joomlaVersion"] = "5.4.1"
    elif variant == "wrong-layout":
        metadata["archiveLayout"]["files"] = "files/"
    elif variant == "unknown-schema":
        metadata["schemaVersion"] = 2
    elif variant == "large-metadata":
        metadata["padding"] = "x" * (1024 * 1024)
    records = dict(payload)
    records["export.json"] = json.dumps(metadata, sort_keys=True).encode()
    records["DEPLOYMENT.md"] = b"Deployment CRC fixture token"
    with zipfile.ZipFile(destination, "w") as archive:
        for name, data in records.items():
            entry = zipfile.ZipInfo(name)
            if variant == "symlink" and name == "site/media/alias.html":
                entry.create_system = 3
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, data)
        if variant == "duplicate":
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                archive.writestr(zipfile.ZipInfo("DEPLOYMENT.md"), records["DEPLOYMENT.md"])

    if variant == "bad-crc":
        destination.write_bytes(destination.read_bytes().replace(b"CRC fixture token", b"CRC fixture TOKEN"))
    elif variant == "truncated":
        destination.write_bytes(destination.read_bytes()[:-22])


if __name__ == "__main__":
    write_fixture(Path(sys.argv[1]), sys.argv[2])
