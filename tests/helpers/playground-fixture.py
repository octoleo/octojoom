"""Write a deterministic synthetic Playground export for the package inspection tests."""

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
    sql = b"CREATE TABLE demo_items (id INTEGER);\n"
    payload = {
        **files,
        "database.sql": sql,
        "database.ndjson": json.dumps(sql.decode().strip()).encode() + b"\n",
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
