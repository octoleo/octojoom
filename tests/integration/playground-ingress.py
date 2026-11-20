#!/usr/bin/env python3
"""Observe the isolated replacement and both loopback ingress paths in CI."""
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def sample(port, host, path, method="GET"):
    connection = http.client.HTTPConnection("127.0.0.1", int(port), timeout=1)
    try:
        connection.request(method, "/" + path, headers={"Host": host})
        response = connection.getresponse()
        return response.status, response.read(256).decode("utf-8", errors="replace").strip()
    except (OSError, http.client.HTTPException):
        return 0, ""
    finally:
        connection.close()


def docker_shim(args):
    real = os.environ["FIXTURE_DOCKER"]
    case = Path(os.environ["INGRESS_CASE"])
    model = next((Path(a) for a in args if a.endswith("/verify.json")), None)
    if model and "exec" in args:
        if (case / "reject").exists():
            return 1
        if "sh" in args and "-c" in args and not (case / "verified").exists():
            result = subprocess.run([real, *args], check=False)
            if result.returncode:
                return result.returncode
            # Hold the actual successful private HTTP probe while the
            # independent observer checks both normal routes and the live model.
            note = case / "verified.tmp"
            note.write_text(str(model), encoding="utf-8")
            note.replace(case / "verified")
            for _ in range(600):
                if (case / "release").exists():
                    return int((case / "reject").exists())
                time.sleep(0.1)
            return 71
    if os.environ["INGRESS_PUBLIC_COMPOSE"] in args and (case / "verified").exists():
        if (("up" in args and "-d" in args) or "start" in args) and not (case / "reject").exists():
            journal = Path((case / "verified").read_text(encoding="utf-8")).parent
            if not (journal / "committed").is_file() or os.environ["INGRESS_MODE"] == "stopped":
                (case / "bad-start").touch()
                return 72
            (case / "public-start").touch()
    if args[:2] == ["volume", "rm"] and os.environ.get("INGRESS_RETAIN_VOLUME") in args[2:]:
        (case / "cleanup-fault").touch()
        for _ in range(600):
            if (case / "release-cleanup").exists():
                break
            time.sleep(0.1)
        return 73
    os.execv(real, [real, *args])


def private_check(model):
    cfg = json.loads(model.read_text(encoding="utf-8"))
    gate = json.loads(Path(os.environ["INGRESS_PUBLIC_COMPOSE"]).read_text(encoding="utf-8"))
    if (gate.get("services") != {} or (model.parent / "committed").exists() or
            (model.parent / "stage").read_text().strip() != "verify"):
        raise RuntimeError("The canonical site was not gated during private verification")
    docker = os.environ["FIXTURE_DOCKER"]
    compose = [docker, "compose", "-p", cfg["name"], "-f", str(model)]
    ids = subprocess.check_output([*compose, "ps", "-q"], text=True).split()
    if not ids or not cfg["name"].startswith("octojoom-verify-"):
        raise RuntimeError("Private verification project was not running")
    network_ids = set()
    for item in json.loads(subprocess.check_output([docker, "inspect", *ids])):
        networks = item["NetworkSettings"]["Networks"]
        labels = {k: v for k, v in item["Config"]["Labels"].items() if k.startswith("traefik.")}
        if (labels != {"traefik.enable": "false"} or item["HostConfig"]["PortBindings"] or
                any(item["NetworkSettings"]["Ports"].values()) or len(networks) != 1):
            raise RuntimeError("Verification container had a public label, port or network")
        network_ids.add(next(iter(networks.values()))["NetworkID"])
    if len(network_ids) != 1:
        raise RuntimeError("Verification containers did not share one network")
    network = json.loads(subprocess.check_output([docker, "network", "inspect", *network_ids]))[0]
    gateway = network["Options"].get("com.docker.network.bridge.gateway_mode_ipv4")
    if not network["Internal"] or network["EnableIPv6"] or gateway != "isolated":
        raise RuntimeError("The running verification bridge did not have isolated IPv4 and disabled IPv6")
    body = subprocess.check_output([
        *compose, "exec", "-T", os.environ["INGRESS_APP"], "curl", "-fsS", "--max-time", "5",
        "-H", "Host: " + os.environ["INGRESS_HOST"],
        "http://" + os.environ["INGRESS_WEB"] + "/" + os.environ["INGRESS_MARKER"],
    ], text=True)
    if body.strip() != os.environ["INGRESS_CANDIDATE"]:
        raise RuntimeError("The privately responding deployment had the wrong marker")


def observe(command):
    case = Path(os.environ["INGRESS_CASE"])
    mode, host = os.environ["INGRESS_MODE"], os.environ["INGRESS_HOST"]
    original, candidate = os.environ["INGRESS_ORIGINAL"], os.environ["INGRESS_CANDIDATE"]
    ports = [os.environ["INGRESS_PROXY_PORT"], os.environ["INGRESS_DIRECT_PORT"]]
    process = subprocess.Popen(command)
    observed = 0
    checked = False
    error = None
    try:
        while process.poll() is None:
            for port in ports:
                status, body = sample(port, host, os.environ["INGRESS_MARKER"])
                if status == 200:
                    if body not in {original, candidate}:
                        raise RuntimeError("A normal route returned an unexpected fixture marker")
                    if mode == "stopped" or (body == candidate and not (case / "public-start").exists()):
                        raise RuntimeError("Replacement marker appeared before a committed public start")
            if (case / "verified").exists() and not (case / "release").exists():
                if not checked:
                    private_check(Path((case / "verified").read_text(encoding="utf-8")))
                    checked = True
                # Multiple HTTP samples while the actual verification containers
                # are serving, well beyond the fixture's Traefik refresh period.
                observed += 1
                if observed >= 8:
                    if mode == "reject":
                        (case / "reject").touch()
                    (case / "release").touch()
            if (case / "cleanup-fault").exists() and not (case / "release-cleanup").exists():
                # Submit through the committed public route before cleanup
                # fails. The main fixture reads the same write afterwards.
                proof = os.environ["INGRESS_WRITE"]
                for _ in range(200):
                    if (sample(ports[0], host, proof, "POST") == (200, "committed fixture write") and
                            sample(ports[1], host, proof) == (200, "committed fixture write")):
                        break
                    time.sleep(0.2)
                else:
                    raise RuntimeError("The committed site could not save and read a fixture write during cleanup")
                (case / "release-cleanup").touch()
            time.sleep(0.2)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        error = str(exc)
    finally:
        (case / "release").touch()
        (case / "release-cleanup").touch()
        status = process.wait()
    if error or not checked or observed < 8 or (case / "bad-start").exists():
        sys.exit(error or "Ingress verification barrier or commit ordering failed")
    if mode in ("running", "cleanup") and not (case / "public-start").exists():
        sys.exit("A committed public start was not observed")
    if mode == "cleanup" and not (case / "cleanup-fault").exists():
        sys.exit("The post-commit cleanup fault was not reached")
    (case / "observed").touch()
    return status


if __name__ == "__main__":
    if Path(sys.argv[0]).name == "docker":
        sys.exit(docker_shim(sys.argv[1:]))
    sys.exit(observe(sys.argv[1:]))
