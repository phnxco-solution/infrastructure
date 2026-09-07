#!/usr/bin/env python3
"""App-only, encrypted backup archives. No Redis or shared infrastructure access.

Python owns validation/state; docker, age and rclone provide their native protocols.
Commands never interpolate application data into a host shell.
"""

import argparse
import contextlib
import datetime as dt
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo


VERSION = 1
DEFAULT_CONFIG = "/etc/infrastructure-backup/config.json"
NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\Z")
RUN_ID = re.compile(r"\d{8}T\d{6}Z-[a-f0-9]{8}\Z")
DEFINER = re.compile(rb"^((?:CREATE\s+|/\*!\d+\s+(?:CREATE\*/\s+/\*!\d+\s+)?))"
                     rb"DEFINER\s*=\s*`(?:``|[^`])*`@`(?:``|[^`])*`\s*")
SYSTEM_DBS = {"mysql", "sys", "information_schema", "performance_schema"}
EXCLUDES = ["logs", "logs/**", "framework/cache", "framework/cache/**",
            "framework/views", "framework/views/**", "framework/sessions",
            "framework/sessions/**", "framework/down", "framework/maintenance.php"]


class BackupError(Exception):
    pass


class BusyError(BackupError):
    pass


def require(condition, message):
    if not condition:
        raise BackupError(message)


def valid_name(value):
    require(isinstance(value, str) and NAME.fullmatch(value), "Invalid app/database/server name")
    return value


def relative(value):
    require(isinstance(value, str) and value and "\\" not in value,
            "Invalid relative path")
    p = PurePosixPath(value)
    require(not p.is_absolute() and all(x not in ("", ".", "..") for x in value.split("/")),
            "Unsafe relative path")
    return p


def digest(path, algorithm="sha256"):
    h = hashlib.new(algorithm)
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def write_json(path, data):
    path = Path(path)
    tmp = path.with_name(path.name + ".partial")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def read_json(path):
    return json.loads(Path(path).read_text())


def run(argv, *, data=None, output=None, timeout=None):
    """Never echo subprocess output on failure: it may include SQL or env values."""
    try:
        result = subprocess.run([str(x) for x in argv], input=data, stdout=output or subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise BackupError(f"Could not run {Path(str(argv[0])).name}: {type(e).__name__}") from e
    require(result.returncode == 0,
            f"{Path(str(argv[0])).name} failed (exit {result.returncode}); no backup/restore success recorded")
    return result.stdout


def safe_root(path):
    p = Path(path).absolute()
    require(p != Path("/") and p == p.resolve(), f"Root must be an absolute, non-symlink directory: {p}")
    return p


def regular_file(path):
    require(stat.S_ISREG(Path(path).lstat().st_mode), f"Expected a regular file: {path}")


def space(path, needed, reserve):
    require(shutil.disk_usage(path).free >= needed + reserve,
            f"Insufficient free space under {path}; need {needed + reserve:,} bytes including reserve")


def copy_stable(source, target):
    """Retry a file changing during its copy; never follow symlinks out of an app."""
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    for _ in range(3):
        before = source.lstat()
        require(stat.S_ISREG(before.st_mode), f"Symlink/special file cannot be backed up: {source}")
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as inp, target.open("wb") as out:
            opened = os.fstat(inp.fileno())
            require(opened.st_ino == before.st_ino, "Source changed while opening")
            shutil.copyfileobj(inp, out, 1024 * 1024)
        after = source.lstat()
        if (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (
                after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            shutil.copystat(source, target, follow_symlinks=False)
            os.chmod(target, stat.S_IMODE(before.st_mode) & 0o777)
            return
    raise BackupError(f"File kept changing during backup: {source}; retry the run")


def copy_storage(source, target, excludes):
    require(source.is_dir() and not source.is_symlink(), f"Storage directory missing/unsafe: {source}")
    target.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory_modes = {target: stat.S_IMODE(source.stat().st_mode) & 0o777}
    for base, dirs, files in os.walk(source, followlinks=False):
        base = Path(base)
        def excluded(name):
            rel = (base / name).relative_to(source).as_posix()
            return any(fnmatch.fnmatchcase(rel, pattern) for pattern in excludes)
        dirs[:] = [d for d in dirs if not excluded(d)]
        for name in dirs:
            src = base / name
            require(not src.is_symlink(), f"Storage symlink is unsupported: {src}")
            dst = target / src.relative_to(source)
            dst.mkdir(mode=0o700, parents=True, exist_ok=True)
            directory_modes[dst] = stat.S_IMODE(src.stat().st_mode) & 0o777
        for name in files:
            if not excluded(name):
                src = base / name
                copy_stable(src, target / src.relative_to(source))
    # mkdir modes are filtered by the CLI's private umask. Restore the source
    # modes explicitly after copying, inside the already private staging parent.
    for directory, mode in reversed(directory_modes.items()):
        os.chmod(directory, mode)


class Manager:
    def __init__(self, config):
        self.config = config
        self.server = valid_name(config.get("server", "production-vps"))
        self.infra = safe_root(config.get("infrastructure_root", "/opt/infrastructure"))
        self.volumes = safe_root(config.get("volumes_root", "/opt/volumes/apps"))
        self.root = safe_root(config.get("backup_root", "/opt/backups/apps"))
        self.zone = ZoneInfo("Europe/Belgrade")
        self.reserve = config.get("minimum_free_bytes", 2 * 1024**3)
        require(isinstance(self.reserve, int) and self.reserve >= 0, "Invalid disk reserve")
        self.remote = config.get("drive_remote", "")
        require(not self.remote or re.match(r"^[A-Za-z0-9_-]+:[^\r\n]*$", self.remote),
                "drive_remote must be an rclone remote:path")
        for parent in (self.infra, self.volumes):
            require(not self.root.is_relative_to(parent) and not parent.is_relative_to(self.root),
                    "Backup, infrastructure and volume roots must not overlap")
        self._apps = None

    def init_local(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        require(not self.root.is_symlink(), "Backup root must not be a symlink")
        os.chmod(self.root, 0o700)
        for name in ("sets", "staging", "safety", "state"):
            folder = self.root / name
            folder.mkdir(mode=0o700, exist_ok=True)
            require(not folder.is_symlink(), "Unsafe backup directory")

    @contextlib.contextmanager
    def locked(self):
        self.init_local()
        with (self.root / "state/operation.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as e:
                raise BusyError("Another backup/upload/restore operation is running") from e
            yield

    def rclone(self, *args, output=None):
        require(self.remote, "Configure drive_remote first")
        argv = ["rclone"]
        if self.config.get("rclone_config"):
            argv += ["--config", self.config["rclone_config"]]
        argv += ["--retries", "3", "--low-level-retries", "5", *args]
        return run(argv, output=output)

    def remote_path(self, suffix=""):
        return self.remote.rstrip("/") + "/" + self.server + ("/" + suffix if suffix else "")

    def compose(self, app, *args):
        return ["docker", "compose", "--project-name", app, "--project-directory", str(self.infra / "apps" / app),
                "-f", str(self.infra / "apps" / app / "docker-compose.yml"), *args]

    def sql(self, query=None, *, command="mysql", arguments=(), output=None):
        container = valid_name(self.config.get("mysql_container", "mysql"))
        argv = ["docker", "exec", "-i", container, "sh", "-c",
                'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec "$@"', "backup", command,
                "--user=root", *arguments]
        if command == "mysql":
            argv += ["--batch", "--raw", "--skip-column-names"]
        return run(argv, data=query.encode() if query is not None else None, output=output)

    def apps(self):
        if self._apps is not None:
            return self._apps
        selected = self.config.get("apps")
        require(isinstance(selected, dict) and selected, "apps must be a nonempty mapping of apps to back up")
        for name, spec in selected.items():
            valid_name(name)
            require(isinstance(spec, dict), "Invalid app settings")
        found = {}
        for name in sorted(selected):
            path = self.infra / "apps" / name / "docker-compose.yml"
            require(path.parent.resolve() == path.parent and not path.is_symlink(), "Unsafe app directory")
            require(path.is_file(), f"Configuration names an app that does not exist: {name}")
            spec = selected[name]
            model = json.loads(run(self.compose(name, "config", "--format", "json")))
            services = model.get("services", {})
            require(services, f"No services in {name}")
            dbs = set()
            laravel = False
            for service in services.values():
                env = service.get("environment", {}) or {}
                for mount in service.get("volumes", []):
                    if mount.get("read_only") or mount.get("type") == "tmpfs":
                        continue
                    require(mount.get("type") == "bind", f"{name} has a writable named volume that needs explicit backup support")
                    source = Path(mount["source"]).resolve()
                    allowed = [self.volumes / name / "storage", self.volumes / name / "logs"]
                    require(any(source == p or source.is_relative_to(p) for p in allowed),
                            f"{name} has persistent data outside supported storage/log paths")
                laravel |= "CONTAINER_ROLE" in env
                host = env.get("DB_HOST")
                db = env.get("DB_DATABASE") or env.get("DB_NAME")
                url = env.get("DATABASE_URL") or env.get("NUXT_DATABASE_URL")
                if url:
                    parsed = urllib.parse.urlsplit(url)
                    if parsed.scheme in ("mysql", "mysql2"):
                        host, db = parsed.hostname, urllib.parse.unquote(parsed.path.lstrip("/"))
                if db:
                    require(host in (None, "mysql", self.config.get("mysql_container", "mysql")),
                            f"{name} uses an external database; configure/support it before backing up")
                    dbs.add(valid_name(db))
            database = spec.get("database", "auto")
            if database != "auto":
                require(database is None or isinstance(database, str), "database must be auto, a name, or null")
                dbs = {valid_name(database)} if database else set()
            require(len(dbs) <= 1, f"{name} has multiple databases; explicit mapping is required")
            owner = spec.get("owner", [82, 82] if laravel else [1000, 1000])
            require(isinstance(owner, list) and len(owner) == 2 and all(type(x) is int and x > 0 for x in owner),
                    f"Invalid owner for {name}")
            configs = spec.get("config_files", [".env", "docker-compose.yml", "nginx.conf"])
            for value in configs:
                relative(value)
            storage = self.volumes / name / "storage"
            require(storage.resolve() == storage and storage.is_dir(), f"Missing/unsafe storage for {name}: {storage}")
            found[name] = {"name": name, "database": next(iter(dbs), None), "owner": owner,
                           "config_files": configs, "excludes": EXCLUDES + spec.get("excludes", []),
                           "services": services, "laravel": laravel}
        names = [a["database"] for a in found.values() if a["database"]]
        require(len(names) == len(set(names)), "Apps share a database; independent restore would affect another app")
        self._apps = found
        return found

    def database_inventory(self):
        names = {a["database"] for a in self.apps().values() if a["database"]}
        actual = set(self.sql("SHOW DATABASES;\n").decode().splitlines()) - SYSTEM_DBS
        require(names == actual,
                f"Database coverage mismatch: unmapped={sorted(actual - names)}, missing={sorted(names - actual)}")
        engines = self.sql("SELECT TABLE_SCHEMA,TABLE_NAME FROM information_schema.TABLES "
                           "WHERE ENGINE IS NOT NULL AND ENGINE <> 'InnoDB' AND TABLE_SCHEMA NOT IN "
                           "('mysql','sys','information_schema','performance_schema');\n").decode().strip()
        require(not engines, "Non-InnoDB app tables found; online transactional backup is not supported for them")

    def images(self, app):
        ids = run(self.compose(app, "ps", "--all", "--quiet")).decode().split()
        result = {}
        for container in ids:
            item = json.loads(run(["docker", "inspect", "--format",
                                   '{{json .}}', container]))
            service = item.get("Config", {}).get("Labels", {}).get("com.docker.compose.service")
            if service:
                result[service] = item["Image"]
        return result

    def capture(self, app, destination, run_id):
        name = app["name"]
        started = dt.datetime.now(dt.timezone.utc).isoformat()
        with tempfile.TemporaryDirectory(dir=self.root / "staging", prefix="capture-") as temp:
            stage = Path(temp)
            source = self.volumes / name / "storage"
            volume_size = sum(p.lstat().st_size for p in source.rglob("*") if not p.is_symlink() and p.is_file())
            db_size = 0
            if app["database"]:
                db_size = int(self.sql("SELECT COALESCE(SUM(DATA_LENGTH+INDEX_LENGTH),0) FROM "
                                      f"information_schema.TABLES WHERE TABLE_SCHEMA='{app['database']}';\n").strip())
            space(self.root, volume_size * 2 + db_size * 4, self.reserve)
            schema = None
            stored_objects = {"functions_or_triggers": 0, "events": 0}
            if app["database"]:
                db = app["database"]
                schema = self.sql("SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM "
                                  f"information_schema.SCHEMATA WHERE SCHEMA_NAME='{db}';\n").decode().strip().split("\t")
                require(len(schema) == 2 and all(NAME.fullmatch(x) for x in schema), "Invalid database schema metadata")
                counts = self.sql(
                    "SELECT (SELECT COUNT(*) FROM information_schema.ROUTINES "
                    f"WHERE ROUTINE_SCHEMA='{db}' AND ROUTINE_TYPE='FUNCTION') + "
                    f"(SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='{db}'), "
                    f"(SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='{db}');\n"
                ).decode().strip().split("\t")
                require(len(counts) == 2, "Could not inventory stored database objects")
                stored_objects = {"functions_or_triggers": int(counts[0]), "events": int(counts[1])}
                with (stage / "database.sql").open("wb") as output:
                    self.sql(command="mysqldump", output=output, arguments=[
                        "--single-transaction", "--quick", "--skip-lock-tables", "--no-tablespaces",
                        "--routines", "--triggers", "--events", "--hex-blob", "--set-gtid-purged=OFF",
                        "--default-character-set=utf8mb4", "--skip-dump-date", db])
                require((stage / "database.sql").stat().st_size > 0, f"Empty database dump for {name}")
            copy_storage(source, stage / "storage", app["excludes"])
            (stage / "config").mkdir(mode=0o700)
            for filename in app["config_files"]:
                src = self.infra / "apps" / name / filename
                if src.exists() or src.is_symlink():
                    require(src.resolve().is_relative_to(self.infra / "apps" / name), "App config escapes app directory")
                    copy_stable(src, stage / "config" / filename)
            files = {}
            directories = {}
            for p in sorted(stage.rglob("*")):
                if p.is_file():
                    files[p.relative_to(stage).as_posix()] = {
                        "sha256": digest(p), "size": p.stat().st_size, "mode": stat.S_IMODE(p.stat().st_mode)}
                elif p.is_dir():
                    directories[p.relative_to(stage).as_posix()] = stat.S_IMODE(p.stat().st_mode)
            manifest = {"version": VERSION, "server": self.server, "app": name, "run": run_id,
                        "started_at": started, "finished_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                        "database": app["database"], "schema": schema, "owner": app["owner"],
                        "stored_objects": stored_objects,
                        "images": self.images(name), "files": files, "directories": directories,
                        "consistency": "online; files and SQL are not atomic"}
            write_json(stage / "manifest.json", manifest)
            recipients = self.config.get("age_recipients", [])
            require(recipients and all(isinstance(r, str) and r.startswith("age1") for r in recipients),
                    "Configure age public recipients first")
            argv = ["age"]
            for recipient in recipients:
                argv += ["--recipient", recipient]
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            partial = destination.with_suffix(destination.suffix + ".partial")
            try:
                with partial.open("xb") as out, tempfile.TemporaryFile() as err:
                    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=out, stderr=err)
                    try:
                        with tarfile.open(fileobj=proc.stdin, mode="w|gz", compresslevel=6) as archive:
                            for p in sorted(stage.rglob("*")):
                                archive.add(p, arcname=p.relative_to(stage).as_posix(), recursive=False)
                        proc.stdin.close()
                        require(proc.wait() == 0, "age encryption failed")
                    finally:
                        if proc.poll() is None:
                            proc.kill()
                            proc.wait()
                require(partial.stat().st_size > 0, "Empty encrypted archive")
                partial.replace(destination)
            finally:
                partial.unlink(missing_ok=True)
            return {"file": destination.name, "sha256": digest(destination),
                    "size": destination.stat().st_size, "database": app["database"]}

    def create_set(self):
        self.database_inventory()
        now = dt.datetime.now(dt.timezone.utc)
        run_id = now.strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(4)
        local = now.astimezone(self.zone)
        rel = local.strftime("%Y/%m/%d/") + run_id
        final = self.root / "sets" / rel
        with tempfile.TemporaryDirectory(dir=self.root / "staging", prefix="set-") as temp:
            stage = Path(temp)
            entries = {}
            for name, app in self.apps().items():
                print(f"Capturing {name} (app stays online)", flush=True)
                entries[name] = self.capture(app, stage / "apps" / f"{name}__{run_id}.tar.gz.age", run_id)
            manifest = {"version": VERSION, "server": self.server, "run": run_id, "path": rel,
                        "created_at": now.isoformat(), "local_time": local.isoformat(), "apps": entries}
            write_json(stage / "manifest.json", manifest)
            sums = [f"{item['sha256']}  apps/{item['file']}" for item in entries.values()]
            sums.append(f"{digest(stage / 'manifest.json')}  manifest.json")
            (stage / "SHA256SUMS").write_text("\n".join(sums) + "\n")
            (stage / "COMPLETE").write_text(digest(stage / "manifest.json") + "\n")
            final.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            stage.rename(final)
        print(f"Local backup complete: {run_id}", flush=True)
        return final

    def validate_set(self, path):
        require(not path.is_symlink(), "Unsafe backup set")
        manifest = read_json(path / "manifest.json")
        require(manifest.get("version") == VERSION and manifest.get("server") == self.server,
                "Wrong backup version/server")
        require(RUN_ID.fullmatch(manifest.get("run", "")), "Invalid backup run ID")
        require((path / "COMPLETE").read_text().strip() == digest(path / "manifest.json"), "Incomplete/corrupt backup set")
        relative(manifest["path"])
        require(path == self.root / "sets" / manifest["path"], "Backup set path mismatch")
        require(manifest["apps"], "Empty backup set")
        for app, entry in manifest["apps"].items():
            valid_name(app)
            expected = f"{app}__{manifest['run']}.tar.gz.age"
            require(entry["file"] == expected, "Invalid archive filename")
            archive = path / "apps" / expected
            regular_file(archive)
            require(archive.stat().st_size == entry["size"] and digest(archive) == entry["sha256"],
                    f"Archive checksum mismatch: {app}")
        return manifest

    def local_sets(self):
        return sorted((self.root / "sets").glob("*/*/*/*/COMPLETE"),
                      key=lambda p: read_json(p.parent / "manifest.json")["created_at"], reverse=True)

    def check_remote(self, path, manifest):
        target = self.remote_path(manifest["path"])
        self.rclone("check", str(path), target, "--one-way", "--exclude", ".uploaded.json*")
        require(self.rclone("cat", target + "/COMPLETE").strip() == digest(path / "manifest.json").encode(),
                "Remote completion marker mismatch")

    def upload_pending(self):
        require(self.remote, "Configure Google Drive before running backups")
        for marker in reversed(self.local_sets()):
            path = marker.parent
            manifest = self.validate_set(path)
            receipt = path / ".uploaded.json"
            if receipt.exists() and read_json(receipt) == {
                    "remote": self.remote_path(manifest["path"]), "sha256": digest(path / "manifest.json")}:
                continue
            target = self.remote_path(manifest["path"])
            print(f"Uploading {manifest['run']}", flush=True)
            self.rclone("copy", str(path), target, "--immutable", "--checksum",
                        "--exclude", "COMPLETE", "--exclude", ".uploaded.json*")
            self.rclone("check", str(path), target, "--one-way", "--exclude", "COMPLETE",
                        "--exclude", ".uploaded.json*")
            self.rclone("copyto", str(marker), target + "/COMPLETE", "--immutable", "--checksum")
            self.check_remote(path, manifest)
            write_json(receipt, {"remote": target, "sha256": digest(path / "manifest.json")})
            write_json(self.root / "state/last-upload.json", {
                "run": manifest["run"], "created_at": manifest["created_at"], "remote": target,
                "uploaded_at": dt.datetime.now(dt.timezone.utc).isoformat(), "sha256": digest(path / "manifest.json")})
        self.prune_local()

    def prune_local(self):
        # Retain safety archives and pending uploads; prune only verified, uploaded sets.
        for marker in self.local_sets()[2:]:
            path = marker.parent
            if not (path / ".uploaded.json").exists():
                continue
            manifest = self.validate_set(path)
            self.check_remote(path, manifest)
            require(path.resolve().is_relative_to(self.root / "sets"), "Unsafe retention path")
            shutil.rmtree(path)
            print(f"Removed uploaded local set {manifest['run']}", flush=True)

    def notify(self, message):
        print(message, file=sys.stderr, flush=True)
        filename = self.config.get("alert_webhook_file")
        if filename:
            try:
                url = Path(filename).read_text().strip()
                require(url.startswith("https://"), "Alert webhook must use HTTPS")
                request = urllib.request.Request(url, json.dumps({"text": f"[{self.server}] {message}"}).encode(),
                                                 {"Content-Type": "application/json"})
                with urllib.request.urlopen(request, timeout=15) as response:
                    require(response.status < 300, "Alert webhook rejected notification")
            except Exception:
                print("Alert delivery failed; check webhook configuration", file=sys.stderr)

    def health(self):
        issues = []
        last = self.root / "state/last-upload.json"
        if not last.exists():
            issues.append("No successful Drive backup has been recorded")
        else:
            info = read_json(last)
            age = dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(info["created_at"])
            if age.total_seconds() > 26 * 3600:
                issues.append("Latest uploaded backup is older than 26 hours")
            require(info["remote"].startswith(self.remote_path() + "/"), "Last upload belongs to a different Drive destination")
            require(self.rclone("cat", info["remote"] + "/COMPLETE").decode().strip() == info["sha256"],
                    "Latest remote completion marker is missing or corrupt")
        if shutil.disk_usage(self.root).free < self.reserve:
            issues.append("VPS free disk space is below the configured reserve")
        quota = json.loads(self.rclone("about", self.remote.split(":", 1)[0] + ":", "--json"))
        total = quota.get("total")
        if total:
            # Google's quota includes Gmail/Photos; rclone's `used` is Drive only.
            used = total - quota["free"] if quota.get("free") is not None else (
                (quota.get("used") or 0) + (quota.get("other") or 0))
            if used / total >= 0.8:
                issues.append("Google Drive is at least 80% full; no files will be deleted automatically")
        for issue in issues:
            self.notify(issue)
        require(not issues, "Backup health check failed")
        print("Backup age, remote availability and storage checks passed")

    def catalog(self, source, date=None, run_id=None, app=None):
        if date:
            try:
                dt.date.fromisoformat(date)
            except ValueError as e:
                raise BackupError("Date must be YYYY-MM-DD") from e
        if run_id and run_id != "latest":
            require(RUN_ID.fullmatch(run_id), "Invalid run ID; select one from list")
        result = []
        if source == "local":
            candidates = [(p.parent.relative_to(self.root / "sets").as_posix(), p.parent)
                          for p in self.local_sets()]
        else:
            prefix = date.replace("-", "/") if date else ""
            lines = self.rclone("lsf", self.remote_path(prefix), "--recursive", "--files-only",
                                "--include", "COMPLETE").decode().splitlines()
            candidates = []
            for line in lines:
                relative(line)
                require(line.endswith("/COMPLETE"), "Unexpected remote catalog entry")
                path = (prefix + "/" if prefix else "") + line.removesuffix("/COMPLETE")
                candidates.append((path, None))
        for path, local in candidates:
            relative(path)
            parts = path.split("/")
            require(len(parts) == 4 and RUN_ID.fullmatch(parts[3]) and
                    re.fullmatch(r"\d{4}/\d{2}/\d{2}", "/".join(parts[:3])), "Invalid catalog path")
            if date and "/".join(parts[:3]) != date.replace("-", "/"):
                continue
            if run_id and run_id != "latest" and parts[3] != run_id:
                continue
            if local:
                raw = (local / "manifest.json").read_bytes()
                complete = (local / "COMPLETE").read_text().strip()
            else:
                raw = self.rclone("cat", self.remote_path(path + "/manifest.json"))
                complete = self.rclone("cat", self.remote_path(path + "/COMPLETE")).decode().strip()
            require(hashlib.sha256(raw).hexdigest() == complete, "Catalog checksum mismatch")
            info = json.loads(raw)
            require(info.get("version") == VERSION and info.get("server") == self.server and
                    info.get("path") == path and info.get("run") == parts[3], "Catalog identity mismatch")
            require(isinstance(info.get("apps"), dict) and info["apps"], "Empty catalog")
            for name, entry in info["apps"].items():
                valid_name(name)
                require(entry.get("file") == f"{name}__{info['run']}.tar.gz.age" and
                        re.fullmatch(r"[a-f0-9]{64}", entry.get("sha256", "")) and
                        type(entry.get("size")) is int and entry["size"] > 0, "Invalid archive entry")
            if not app or app in info["apps"]:
                result.append(info)
        result.sort(key=lambda x: x["created_at"], reverse=True)
        return result

    @contextlib.contextmanager
    def selected_archive(self, args):
        if args.file:
            require(args.source == "local" and args.run == "latest", "--file cannot be combined with Drive/run selection")
            source = Path(args.file).resolve()
            regular_file(source)
            yield source, None
            return
        require(args.app, "Select --app (or provide --file)")
        sets = self.catalog(args.source, run_id=args.run, app=args.app)
        require(sets, "No matching complete backup found")
        info = sets[0]
        entry = info["apps"][args.app]
        if args.source == "local":
            source = self.root / "sets" / info["path"] / "apps" / entry["file"]
            regular_file(source)
            require(digest(source) == entry["sha256"], "Local archive checksum mismatch")
            yield source, info
        else:
            with tempfile.TemporaryDirectory(prefix="app-backup-download-") as temp:
                folder = Path(temp)
                space(folder, entry["size"], self.reserve)
                source = folder / entry["file"]
                self.rclone("copyto", self.remote_path(info["path"] + "/apps/" + entry["file"]),
                            str(source), "--immutable", "--checksum")
                require(source.stat().st_size == entry["size"] and digest(source) == entry["sha256"],
                        "Downloaded archive checksum mismatch")
                yield source, info

    def extract(self, archive, identity, destination, expected_app=None, expected_run=None):
        require(identity, "Provide --identity /path/to/recovery-key.txt or BACKUP_IDENTITY_FILE")
        identity = Path(identity).resolve()
        regular_file(identity)
        destination = Path(destination).absolute()
        require(not destination.exists() and not destination.is_symlink(), "Extraction destination must not exist")
        require(destination.parent.is_dir() and destination.parent.resolve() == destination.parent,
                "Extraction parent must exist and contain no symlinks")
        with tempfile.TemporaryDirectory(dir=destination.parent, prefix=".unpack-") as temp:
            stage = Path(temp)
            compressed = stage / "archive.tar.gz"
            space(stage, Path(archive).stat().st_size, self.reserve)
            with compressed.open("xb") as out:
                run(["age", "--decrypt", "--identity", identity, archive], output=out)
            payload = stage / "payload"
            payload.mkdir(mode=0o700)
            with tarfile.open(compressed, "r:gz") as tar:
                members = tar.getmembers()
                seen = set()
                total = 0
                for item in members:
                    relative(item.name)
                    require(item.name not in seen, "Duplicate archive path")
                    seen.add(item.name)
                    require((item.isfile() or item.isdir()) and not item.sparse,
                            "Archive links, devices and sparse entries are not accepted")
                    require(item.size >= 0, "Invalid archive size")
                    total += item.size
                require("manifest.json" in seen and len(members) <= 1000000, "Invalid archive manifest/member count")
                space(stage, total, self.reserve)
                # Extract by hand: only regular files/directories into a new private directory.
                for item in members:
                    target = payload / item.name
                    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    if item.isdir():
                        target.mkdir(exist_ok=True, mode=0o700)
                    else:
                        with tar.extractfile(item) as inp, target.open("xb") as out:
                            shutil.copyfileobj(inp, out, 1024 * 1024)
                        os.chmod(target, 0o600)
            info = read_json(payload / "manifest.json")
            require(info.get("version") == VERSION, "Unsupported archive version")
            valid_name(info.get("app"))
            require(RUN_ID.fullmatch(info.get("run", "")), "Invalid archive run ID")
            require(not expected_app or info["app"] == expected_app, "Archive belongs to a different app")
            require(not expected_run or info["run"] == expected_run, "Archive belongs to a different run")
            files = info.get("files")
            require(isinstance(files, dict), "Invalid file manifest")
            directories = info.get("directories")
            require(isinstance(directories, dict), "Invalid directory manifest")
            actual_dirs = {p.relative_to(payload).as_posix() for p in payload.rglob("*") if p.is_dir()}
            require(actual_dirs == set(directories), "Archive directory inventory mismatch")
            for name, mode in directories.items():
                relative(name)
                require(name in ("storage", "config") or name.startswith(("storage/", "config/")), "Unexpected archive directory")
                require(type(mode) is int and 0 <= mode <= 0o777, "Invalid directory mode")
            actual = {p.relative_to(payload).as_posix() for p in payload.rglob("*") if p.is_file()}
            require(actual == set(files) | {"manifest.json"}, "Archive file inventory mismatch")
            for name, entry in files.items():
                relative(name)
                require(name == "database.sql" or name.startswith(("storage/", "config/")), "Unexpected archive file")
                p = payload / name
                require(p.stat().st_size == entry["size"] and digest(p) == entry["sha256"], "Archive file checksum mismatch")
                require(type(entry.get("mode")) is int and 0 <= entry["mode"] <= 0o777, "Invalid file mode")
            require((payload / "storage").is_dir() and (payload / "config").is_dir(), "Missing archive directories")
            require(bool(info.get("database")) == ("database.sql" in files), "Database payload mismatch")
            if info.get("database"):
                valid_name(info["database"])
                require(isinstance(info.get("schema"), list) and len(info["schema"]) == 2 and
                        all(NAME.fullmatch(x) for x in info["schema"]), "Invalid schema metadata")
            for name, entry in files.items():
                os.chmod(payload / name, entry["mode"] & 0o777)
            payload.rename(destination)
            return info

    def running_services(self, name):
        # Restart-policy backoff still represents a live writer: it can resume
        # without an operator starting it. Inspect every container, including
        # stopped ones, rather than filtering away those transitions.
        ids = run(self.compose(name, "ps", "--all", "--quiet")).decode().split()
        active = set()
        for container in ids:
            item = json.loads(run(["docker", "inspect", "--format", "{{json .}}", container]))
            state = item["State"]
            require(not state.get("Paused") and state.get("Status") != "removing",
                    "App has a paused/removing container; resolve its state before restoring")
            service = item.get("Config", {}).get("Labels", {}).get("com.docker.compose.service")
            require(service in self.apps()[name]["services"],
                    "App project has an unknown/orphan container; resolve it before restoring")
            if state.get("Running") or state.get("Restarting"):
                active.add(service)
        return sorted(active)

    def validate_config_restore(self, app, payload, expected_images, allow_image_mismatch=False):
        """Config recovery may change values, but cannot move an app's data/topology."""
        name = app["name"]
        archived = {p.relative_to(payload / "config").as_posix()
                    for p in (payload / "config").rglob("*") if p.is_file()}
        require(archived <= set(app["config_files"]), "Archive contains configuration outside the current allowlist")
        current = json.loads(run(self.compose(name, "config", "--format", "json")))
        with tempfile.TemporaryDirectory(dir=self.root / "staging", prefix="config-check-") as temp:
            draft = Path(temp)
            live = self.infra / "apps" / name
            for filename in app["config_files"]:
                target = draft / filename
                source = payload / "config" / filename if filename in archived else live / filename
                if source.exists() or source.is_symlink():
                    require(source.resolve().is_relative_to(payload / "config" if filename in archived else live),
                            "App config escapes its directory")
                    copy_stable(source, target)
            proposed = json.loads(run(["docker", "compose", "--project-name", name,
                                       "--project-directory", str(draft), "-f", str(draft / "docker-compose.yml"),
                                       "config", "--format", "json"]))

            def topology(model, root):
                # Compose resolves relative bind/config paths against its project
                # directory. Compare their final live destinations, not staging.
                def normalize(value):
                    if isinstance(value, dict):
                        return {key: normalize(item) for key, item in value.items() if key != "environment"}
                    if isinstance(value, list):
                        return [normalize(item) for item in value]
                    if isinstance(value, str) and (value == str(root) or value.startswith(str(root) + "/")):
                        return str(live) + value[len(str(root)):]
                    return value
                return normalize(model)

            require(topology(current, live) == topology(proposed, draft),
                    "Archived configuration changes the app service/image/mount topology; unpack and review it separately")
            for service, settings in current["services"].items():
                before = settings.get("environment", {}) or {}
                after = proposed["services"][service].get("environment", {}) or {}
                for key in ("DB_HOST", "DB_PORT", "DB_DATABASE", "DB_NAME", "DATABASE_URL", "NUXT_DATABASE_URL"):
                    require(before.get(key) == after.get(key),
                            "Archived configuration changes the database connection; provision/review it before restoring")
            images = {}
            for service, settings in proposed["services"].items():
                if service in expected_images:
                    require(settings.get("image"), "Config restoration requires an existing image for each active service")
                    image_id = run(["docker", "image", "inspect", "--format", "{{.Id}}", settings["image"]]).decode().strip()
                    require(allow_image_mismatch or image_id == expected_images[service],
                            "A configured image tag now resolves to a different image; review it before restoring")
                    images[service] = image_id
            return images

    def start_and_check(self, name, services, with_config=False, images=None):
        if not services:
            return
        if with_config:
            require(images and set(services) <= set(images), "Missing verified image IDs for config restoration")
            with tempfile.TemporaryDirectory(dir=self.root / "staging", prefix="restore-images-") as temp:
                override = Path(temp) / "images.json"
                write_json(override, {"services": {service: {"image": images[service]} for service in services}})
                run(self.compose(name, "-f", str(override), "up", "-d", "--no-deps", "--pull", "never", "--no-build", *services))
        else:
            run(self.compose(name, "start", *services))
        deadline = time.monotonic() + self.config.get("restore_health_timeout_seconds", 180)
        while time.monotonic() < deadline:
            ids = run(self.compose(name, "ps", "--all", "--quiet", *services)).decode().split()
            good = len(ids) >= len(services)
            for container in ids:
                state = json.loads(run(["docker", "inspect", "--format", "{{json .State}}", container]))
                good &= state.get("Running", False) and state.get("Health", {}).get("Status", "healthy") == "healthy"
            if good:
                return
            time.sleep(2)
        raise BackupError(f"{name} did not become healthy after restore")

    def import_database(self, app, payload, schema):
        db = valid_name(app["database"])
        charset, collation = schema
        require(all(NAME.fullmatch(x) for x in schema), "Invalid schema metadata")
        partial_revokes = self.sql("SELECT @@partial_revokes;\n").strip()
        require(partial_revokes in (b"0", b"1"), "Could not determine database grant semantics")
        # With partial revokes disabled, underscores in database grants are SQL
        # wildcards even inside backticks. Scope the grant to this exact schema.
        grant_db = db.replace("_", r"\_") if partial_revokes == b"0" else db
        username = "restore_" + secrets.token_hex(8)
        password = secrets.token_hex(32)
        # Scope imported SQL to this database; never import archive SQL as root.
        # Keep the account locked after success: views/routines/triggers can use it
        # as their DEFINER. Removing it would break those restored objects.
        self.sql(f"CREATE USER '{username}'@'localhost' IDENTIFIED BY '{password}';\n")
        imported = False
        try:
            self.sql(f"DROP DATABASE `{db}`;\nCREATE DATABASE `{db}` CHARACTER SET {charset} COLLATE {collation};\n"
                     f"GRANT ALL PRIVILEGES ON `{grant_db}`.* TO '{username}'@'localhost';\n")
            container = valid_name(self.config.get("mysql_container", "mysql"))
            script = 'IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec mysql --binary-mode=1 --local-infile=0 --user="$1" "$2"'
            with tempfile.TemporaryFile() as err, tempfile.TemporaryFile() as out:
                proc = subprocess.Popen(["docker", "exec", "-i", container, "sh", "-c", script,
                                         "restore", username, db], stdin=subprocess.PIPE, stdout=out, stderr=err)
                try:
                    proc.stdin.write((password + "\n").encode())
                    with (payload / "database.sql").open("rb") as sql:
                        for line in sql:
                            # mysqldump emits definers only in these CREATE/comment
                            # prefixes. INSERT values and other SQL are untouched.
                            proc.stdin.write(DEFINER.sub(rb"\1", line))
                    proc.stdin.close()
                    require(proc.wait() == 0, "Database import failed; app remains stopped, use the safety archive to recover")
                    imported = True
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()
        finally:
            if imported:
                self.sql(f"ALTER USER '{username}'@'localhost' ACCOUNT LOCK;\n")
            else:
                self.sql(f"DROP USER IF EXISTS '{username}'@'localhost';\n")

    def restore(self, args):
        require(args.app, "Restore requires an explicit --app")
        app = self.apps().get(valid_name(args.app))
        require(app, "Unknown target app")
        self.database_inventory()
        with self.selected_archive(args) as (archive, catalog):
            with tempfile.TemporaryDirectory(dir=self.root / "staging", prefix="restore-") as temp:
                payload = Path(temp) / "payload"
                info = self.extract(archive, args.identity, payload, args.app, catalog["run"] if catalog else None)
                require(info["database"] == app["database"], "Archive database does not match this app's configured database")
                objects = info.get("stored_objects", {})
                if objects.get("functions_or_triggers"):
                    settings = self.sql("SELECT @@log_bin,@@log_bin_trust_function_creators;\n").decode().strip().split("\t")
                    require(settings in (["0", "0"], ["0", "1"], ["1", "1"]),
                            "This archive has functions/triggers, but MySQL binary-log policy blocks a scoped import; "
                            "review the server policy before restoring. No services stopped or data changed")
                require(not objects.get("events"),
                        "This archive includes MySQL scheduled events; use unpack and a reviewed database recovery "
                        "to avoid running old events during restore. No services stopped or data changed")
                current_images = self.images(args.app)
                if not args.allow_image_mismatch:
                    require(info.get("images") == current_images,
                            "App image versions differ; review compatibility, then explicitly use --allow-image-mismatch")
                if args.with_config:
                    app = dict(app, restore_images=self.validate_config_restore(
                        app, payload, current_images, args.allow_image_mismatch))
                print(f"Restore {args.app} from {info['run']}\nDatabase: {app['database'] or '(none)'}\n"
                      f"Storage: {self.volumes / args.app / 'storage'}\nRestore app configuration: {args.with_config}\n"
                      "The selected app and its workers will stop. Redis and other apps will not be restored.", flush=True)
                if args.verify_only:
                    print("Archive and target verified; no services stopped and no live data changed")
                    return
                require(sys.stdin.isatty(), "Live restore requires an interactive terminal; use --verify-only for unattended checks")
                require(input(f"Type RESTORE {args.app} to replace its data: ") == f"RESTORE {args.app}", "Restore cancelled")
                self.apply_restore(app, payload, info, args.with_config)

    def apply_restore(self, app, payload, info, with_config):
        name = app["name"]
        active = self.running_services(name)
        require(set(active) <= set(app["services"]), "Unexpected running service in app project")
        restore_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(4)
        journal = self.root / "safety" / f"{name}__{restore_id}.json"
        checkpoint = self.root / "safety" / f"{name}__{restore_id}.tar.gz.age"
        state = {"app": name, "source_run": info["run"], "running_services": active,
                 "safety_archive": str(checkpoint), "phase": "stopping"}
        write_json(journal, state)
        mutated = False
        succeeded = False
        storage = self.volumes / name / "storage"
        old = storage.with_name(".pre-restore-" + restore_id)
        replacement = storage.with_name(".restore-" + restore_id)
        require(not old.exists() and not replacement.exists(), "Restore staging path already exists")
        try:
            print("Stopping the selected app; respecting configured worker shutdown grace periods", flush=True)
            # Stop the entire declared project so an exited container with a
            # restart pending cannot start writing after the initial snapshot.
            run(self.compose(name, "stop", *app["services"]))
            require(not self.running_services(name), "App writers did not stop; restore aborted")
            state["phase"] = "safety-backup"
            write_json(journal, state)
            self.capture(app, checkpoint, restore_id)
            state["safety_sha256"] = digest(checkpoint)
            print(f"Safety archive: {checkpoint}", flush=True)
            required = sum(p.stat().st_size for p in (payload / "storage").rglob("*") if p.is_file())
            space(storage.parent, required, self.reserve)
            shutil.copytree(payload / "storage", replacement)
            # Preserve operational logs; rebuild disposable Laravel directories without touching Redis.
            if (storage / "logs").is_dir():
                copy_storage(storage / "logs", replacement / "logs", [])
            if app["laravel"]:
                for folder in ("logs", "framework/cache/data", "framework/sessions", "framework/views"):
                    (replacement / folder).mkdir(parents=True, exist_ok=True, mode=0o755)
            uid, gid = app["owner"]
            for p in [replacement, *replacement.rglob("*")]:
                require(not p.is_symlink(), "Unsafe restore path")
                if os.geteuid() == 0:
                    os.chown(p, uid, gid)
                else:
                    require((p.stat().st_uid, p.stat().st_gid) == (uid, gid), "Root is required to restore container ownership")
                if p.is_dir():
                    relative_dir = "storage" + ("/" + p.relative_to(replacement).as_posix() if p != replacement else "")
                    os.chmod(p, info["directories"].get(relative_dir, 0o755))
            state["phase"] = "applying"
            write_json(journal, state)
            mutated = True
            if app["database"]:
                self.import_database(app, payload, info["schema"])
            state["previous_storage"] = str(old)
            write_json(journal, state)
            storage.rename(old)
            try:
                replacement.rename(storage)
            except BaseException:
                old.rename(storage)
                raise
            if with_config:
                for p in sorted((payload / "config").rglob("*")):
                    if p.is_file():
                        target = self.infra / "apps" / name / p.relative_to(payload / "config")
                        require(target.parent.resolve().is_relative_to(self.infra / "apps" / name) and not target.is_symlink(),
                                "Unsafe config restore destination")
                        copy_stable(p, target)
                        os.chmod(target, 0o600)
            state["phase"] = "health-check"
            write_json(journal, state)
            self.start_and_check(name, active, with_config, app.get("restore_images"))
            succeeded = True
            state["phase"] = "complete"
            write_json(journal, state)
            shutil.rmtree(old)
            print(f"Restored {name}. Safety backup retained at {checkpoint}", flush=True)
        finally:
            if not succeeded:
                state["phase"] = "failed-after-write" if mutated else "aborted-before-write"
                write_json(journal, state)
                if mutated:
                    # A health check can fail after starting services; bring only this app back down.
                    try:
                        run(self.compose(name, "stop", *app["services"]))
                    finally:
                        self.notify(f"Restore of {name} failed. App left stopped; recovery details: {journal}")
                elif active:
                    self.start_and_check(name, active)
            if replacement.exists():
                shutil.rmtree(replacement)


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--config", default=DEFAULT_CONFIG)
    commands = cli.add_subparsers(dest="command", required=True)
    for name in ("run", "upload", "check", "health", "list", "download", "unpack", "restore"):
        p = commands.add_parser(name)
        p.add_argument("--config", default=argparse.SUPPRESS)
        if name in ("list", "download", "unpack", "restore"):
            p.add_argument("--source", choices=("local", "drive"), default="local")
            p.add_argument("--app")
            p.add_argument("--run", default="latest" if name != "list" else None)
        if name == "list":
            p.add_argument("--date", help="YYYY-MM-DD in Europe/Belgrade")
        if name in ("unpack", "restore"):
            p.add_argument("--file")
            p.add_argument("--identity", default=os.environ.get("BACKUP_IDENTITY_FILE"))
        if name == "download":
            p.set_defaults(file=None)
        if name in ("download", "unpack"):
            p.add_argument("--to", required=True)
        if name == "restore":
            p.add_argument("--with-config", action="store_true")
            p.add_argument("--allow-image-mismatch", action="store_true")
            p.add_argument("--verify-only", action="store_true")
    return cli


def main(argv=None):
    os.umask(0o077)
    args = parser().parse_args(argv)
    manager = None
    try:
        config_path = Path(args.config)
        if not config_path.exists():
            require(args.command == "unpack" and args.file, f"Configuration missing: {config_path}; see backups/README.md")
            config = {}
        else:
            config = read_json(config_path)
        manager = Manager(config)
        if getattr(args, "app", None):
            valid_name(args.app)
        if args.command == "health":
            # Read-only health monitoring must still run during a long backup/restore.
            manager.init_local()
            manager.health()
            return 0
        if args.command in ("run", "upload", "restore", "check", "health"):
            with manager.locked():
                if args.command == "run":
                    require(manager.remote and config.get("age_recipients"), "Configure Drive and encryption before running")
                    # Keep capturing daily during a Drive outage while disk space permits.
                    try:
                        manager.upload_pending()
                    except BackupError:
                        manager.notify("Pending uploads could not finish; attempting today's local backup with disk reserve enforced")
                    manager.create_set()
                    manager.upload_pending()
                elif args.command == "upload":
                    manager.upload_pending()
                elif args.command == "restore":
                    manager.restore(args)
                elif args.command == "health":
                    manager.health()
                else:
                    for binary in ("docker", "age", "rclone"):
                        require(shutil.which(binary), f"Missing dependency: {binary}")
                    require(config.get("age_recipients"), "Configure age recipients")
                    with tempfile.TemporaryFile() as out:
                        encryption = ["age"]
                        for recipient in config["age_recipients"]:
                            encryption += ["-r", recipient]
                        run(encryption, data=b"backup preflight\n", output=out)
                    manager.database_inventory()
                    manager.rclone("lsf", manager.remote, "--max-depth", "1")
                    space(manager.root, 0, manager.reserve)
                    for name, app in manager.apps().items():
                        print(f"{name}: database={app['database'] or '(none)'}, owner={app['owner']}")
                    print("Preflight passed; no app data changed")
        elif args.command == "list":
            for info in manager.catalog(args.source, args.date, args.run, args.app):
                total = sum(x["size"] for x in info["apps"].values())
                print(f"{info['run']}  {info['local_time']}  {total:,} bytes  {', '.join(sorted(info['apps']))}")
        else:
            destination = Path(args.to).absolute()
            require(destination.parent.is_dir() and destination.parent.resolve() == destination.parent,
                    "Destination parent must exist and contain no symlinks")
            require(not destination.exists() and not destination.is_symlink(), "Destination must not already exist")
            with manager.selected_archive(args) as (archive, catalog):
                if args.command == "download":
                    space(destination.parent, archive.stat().st_size, manager.reserve)
                    with tempfile.TemporaryDirectory(dir=destination.parent, prefix=".download-") as temp:
                        target = Path(temp) / "archive"
                        copy_stable(archive, target)
                        target.rename(destination)
                    print(f"Downloaded and verified: {destination}")
                else:
                    info = manager.extract(archive, args.identity, destination, args.app,
                                           catalog["run"] if catalog else None)
                    print(f"Unpacked {info['app']} ({info['run']}) into {destination}; live data unchanged")
        return 0
    except BusyError as e:
        if args.command == "upload":
            print("Upload retry skipped: another operation is running")
            return 0
        if manager:
            manager.notify(str(e))
        return 1
    except (BackupError, OSError, ValueError, KeyError, TypeError, tarfile.TarError, EOFError) as e:
        message = str(e) if isinstance(e, BackupError) else f"Operation failed: {type(e).__name__} (details suppressed to protect secrets)"
        if manager:
            manager.notify(message)
        else:
            print(message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise BackupError(f"Interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    sys.exit(main())
