"""Recovery-focused tests. All files live in an isolated temporary directory.

age and rclone are real binaries; Docker boundaries are controlled test doubles.
Run: python3 -m unittest discover -s backups -p 'test_*.py' -v
"""

import argparse
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("backup_manager", Path(__file__).with_name("manager.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class FixtureManager(m.Manager):
    def __init__(self, config):
        super().__init__(config)
        self.active = ["app", "worker"]
        self.events = []
        self.fail_import = False
        self.fail_health = False
        self.fail_capture = False
        self._apps = {"demo": {"name": "demo", "database": "demo", "owner": [os.getuid(), os.getgid()],
                               "config_files": [".env", "docker-compose.yml"], "excludes": m.EXCLUDES,
                               "services": {"app": {}, "worker": {}}, "laravel": True}}

    def database_inventory(self):
        self.events.append("inventory")

    def sql(self, query=None, *, command="mysql", arguments=(), output=None):
        self.events.append("dump" if command == "mysqldump" else "query")
        if command == "mysqldump":
            output.write(b"CREATE TABLE example (id int);\nINSERT INTO example VALUES (42);\n")
            return None
        if "SUM(" in query:
            return b"1024\n"
        if "DEFAULT_CHARACTER_SET_NAME" in query:
            return b"utf8mb4\tutf8mb4_unicode_ci\n"
        if "information_schema.ROUTINES" in query:
            return b"0\t0\n"
        raise AssertionError(query)

    def images(self, app):
        return {"app": "sha256:fixture-image", "worker": "sha256:fixture-image"}

    def capture(self, *args):
        if self.fail_capture:
            raise m.BackupError("injected capture failure")
        return super().capture(*args)

    def running_services(self, name):
        return list(self.active)

    def start_and_check(self, name, services, with_config=False, images=None):
        self.events.append("start")
        self.active = list(services)
        if self.fail_health:
            raise m.BackupError("injected health failure")

    def import_database(self, app, payload, schema):
        if self.active:
            raise AssertionError("Database changed while app was running")
        self.events.append("import")
        if self.fail_import:
            raise m.BackupError("injected import failure")
        self.imported = (payload / "database.sql").read_text()

    def notify(self, message):
        self.events.append("notification")


@unittest.skipUnless(shutil.which("age") and shutil.which("rclone"), "Install age and rclone for integration tests")
class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="infrastructure-backup-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.infra = self.base / "infra"
        self.storage = self.base / "volumes/demo/storage"
        self.storage.mkdir(parents=True)
        (self.storage / "uploads").mkdir()
        (self.storage / "uploads/photo.txt").write_text("original upload\n")
        (self.storage / "logs").mkdir()
        (self.storage / "logs/runtime.log").write_text("operational log\n")
        app = self.infra / "apps/demo"
        app.mkdir(parents=True)
        # Synthetic configuration outside the infrastructure workspace; never read real .env files.
        (app / ".env").write_text("DB_PASSWORD=synthetic-only\n")
        (app / "docker-compose.yml").write_text("services: {}\n")
        self.identity = self.base / "identity.txt"
        subprocess.run(["age-keygen", "-o", str(self.identity)], check=True, capture_output=True)
        recipient = subprocess.check_output(["age-keygen", "-y", str(self.identity)]).decode().strip()
        self.drive = self.base / "drive"
        self.drive.mkdir()
        self.rclone_config = self.base / "rclone.conf"
        self.rclone_config.write_text("[testdrive]\ntype = local\n")
        self.config = {"server": "test-vps", "infrastructure_root": str(self.infra),
                       "volumes_root": str(self.base / "volumes"), "backup_root": str(self.base / "backups"),
                       "drive_remote": f"testdrive:{self.drive}", "rclone_config": str(self.rclone_config),
                       "age_recipients": [recipient], "minimum_free_bytes": 0}
        self.manager = FixtureManager(self.config)
        self.manager.init_local()

    def create(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return self.manager.create_set()

    def upload(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.manager.upload_pending()

    def extract(self, path, name="unpacked"):
        info = m.read_json(path / "manifest.json")
        archive = path / "apps" / info["apps"]["demo"]["file"]
        target = self.base / name
        result = self.manager.extract(archive, self.identity, target, "demo", info["run"])
        return target, result

    @contextlib.contextmanager
    def docker_stop(self):
        original = m.run
        def command(argv, **kwargs):
            if argv[0] == "docker":
                self.assertIn("stop", argv)
                self.manager.events.append("stop")
                self.manager.active = []
                return b""
            return original(argv, **kwargs)
        with patch.object(m, "run", command):
            yield

    def test_online_backup_round_trip_has_only_app_payload(self):
        path = self.create()
        self.assertEqual(self.manager.active, ["app", "worker"])
        target, info = self.extract(path)
        self.assertEqual((target / "storage/uploads/photo.txt").read_text(), "original upload\n")
        self.assertIn("42", (target / "database.sql").read_text())
        self.assertEqual((target / "config/.env").read_text(), "DB_PASSWORD=synthetic-only\n")
        self.assertFalse((target / "storage/logs").exists())
        self.assertEqual({p.name for p in target.iterdir()}, {"database.sql", "storage", "config", "manifest.json"})
        self.assertNotIn("stop", self.manager.events)
        self.assertEqual(info["database"], "demo")

    def test_cloud_retains_all_sets_while_local_keeps_two(self):
        # Force IDs onto successive dates so sorting is independent of the random suffix.
        original_datetime = m.dt.datetime
        for day in (1, 2, 3):
            class Clock(original_datetime):
                @classmethod
                def now(cls, tz=None):
                    return original_datetime(2026, 9, day, 1, tzinfo=dt.timezone.utc).astimezone(tz)
            with patch.object(m.dt, "datetime", Clock):
                self.create()
                self.upload()
        self.assertEqual(len(self.manager.local_sets()), 2)
        self.assertEqual(len(list(self.drive.rglob("COMPLETE"))), 3)
        self.assertEqual(len(self.manager.catalog("drive")), 3)
        self.assertEqual(len(self.manager.catalog("drive", date="2026-09-01")), 1)

    def test_failed_upload_has_no_completion_marker_and_retries(self):
        self.create()
        original = self.manager.rclone
        def fail_check(*args, **kwargs):
            if args[0] == "check":
                raise m.BackupError("injected network failure")
            return original(*args, **kwargs)
        with patch.object(self.manager, "rclone", fail_check), self.assertRaises(m.BackupError):
            self.upload()
        self.assertEqual(len(self.manager.local_sets()), 1)
        self.assertEqual(list(self.drive.rglob("COMPLETE")), [])
        self.assertEqual(list(self.manager.root.rglob(".uploaded.json")), [])
        self.upload()
        self.assertEqual(len(list(self.drive.rglob("COMPLETE"))), 1)

    def test_pending_backups_are_never_pruned(self):
        for _ in range(3):
            self.create()
        self.manager.prune_local()
        self.assertEqual(len(self.manager.local_sets()), 3)

    def test_download_specific_drive_archive_then_unpack(self):
        path = self.create()
        self.upload()
        run_id = m.read_json(path / "manifest.json")["run"]
        args = argparse.Namespace(file=None, source="drive", app="demo", run=run_id)
        with self.manager.selected_archive(args) as (archive, info):
            self.manager.extract(archive, self.identity, self.base / "from-drive", "demo", info["run"])
        self.assertEqual((self.base / "from-drive/storage/uploads/photo.txt").read_text(), "original upload\n")

    def test_wrong_key_and_wrong_app_leave_no_extraction(self):
        path = self.create()
        info = m.read_json(path / "manifest.json")
        archive = path / "apps" / info["apps"]["demo"]["file"]
        wrong = self.base / "wrong-key"
        subprocess.run(["age-keygen", "-o", str(wrong)], check=True, capture_output=True)
        for identity, app in ((wrong, "demo"), (self.identity, "another-app")):
            with self.assertRaises(m.BackupError):
                self.manager.extract(archive, identity, self.base / "rejected", app)
            self.assertFalse((self.base / "rejected").exists())

    def test_corrupt_remote_archive_is_rejected(self):
        self.create()
        self.upload()
        archive = next(self.drive.rglob("*.age"))
        archive.write_bytes(b"corrupt")
        args = argparse.Namespace(file=None, source="drive", app="demo", run="latest")
        with self.assertRaises(m.BackupError), self.manager.selected_archive(args):
            self.fail("Corrupt archive must not be yielded")

    def malicious(self, member):
        tar_path = self.base / "bad.tar.gz"
        with tarfile.open(tar_path, "w:gz") as tar:
            tar.addfile(member)
        encrypted = self.base / "bad.age"
        subprocess.run(["age", "-r", self.config["age_recipients"][0], "-o", str(encrypted), str(tar_path)], check=True)
        return encrypted

    def test_path_traversal_and_symlinks_are_rejected(self):
        for kind in ("traversal", "symlink"):
            member = tarfile.TarInfo("../outside" if kind == "traversal" else "escape")
            if kind == "symlink":
                member.type = tarfile.SYMTYPE
                member.linkname = "/etc"
            archive = self.malicious(member)
            with self.assertRaises(m.BackupError):
                self.manager.extract(archive, self.identity, self.base / "rejected")
            archive.unlink()
        self.assertFalse((self.base / "rejected").exists())

    def test_storage_symlink_cannot_capture_external_data(self):
        (self.storage / "escape").symlink_to(self.infra)
        with self.assertRaises(m.BackupError):
            self.create()
        self.assertEqual(self.manager.local_sets(), [])

    def test_successful_restore_stops_writers_preserves_config_and_logs(self):
        path = self.create()
        payload, info = self.extract(path)
        (self.storage / "uploads/photo.txt").write_text("changed\n")
        (self.storage / "uploads/new.txt").write_text("after the backup\n")
        (self.infra / "apps/demo/.env").write_text("CURRENT_CONFIG=yes\n")
        with self.docker_stop(), contextlib.redirect_stdout(io.StringIO()):
            self.manager.apply_restore(self.manager.apps()["demo"], payload, info, False)
        self.assertLess(self.manager.events.index("stop"), self.manager.events.index("import"))
        self.assertLess(self.manager.events.index("import"), self.manager.events.index("start"))
        self.assertEqual(self.manager.active, ["app", "worker"])
        self.assertEqual((self.storage / "uploads/photo.txt").read_text(), "original upload\n")
        self.assertFalse((self.storage / "uploads/new.txt").exists())
        self.assertEqual((self.storage / "logs/runtime.log").read_text(), "operational log\n")
        self.assertEqual((self.infra / "apps/demo/.env").read_text(), "CURRENT_CONFIG=yes\n")
        self.assertEqual(len(list((self.manager.root / "safety").glob("*.age"))), 1)

    def test_restarting_worker_is_stopped_before_database_import(self):
        path = self.create()
        payload, info = self.extract(path)
        states = {"app": "running", "worker": "restarting"}
        original = m.run

        def command(argv, **kwargs):
            if argv[0] != "docker":
                return original(argv, **kwargs)
            if argv[1] == "inspect":
                service = argv[-1]
                status = states[service]
                return json.dumps({"State": {"Running": status == "running", "Restarting": status == "restarting",
                                              "Paused": False, "Status": status},
                                   "Config": {"Labels": {"com.docker.compose.service": service}}}).encode()
            if "ps" in argv:
                self.assertIn("--all", argv)
                return b"app\nworker\n"
            self.assertIn("stop", argv)
            self.assertEqual(set(argv[argv.index("stop") + 1:]), {"app", "worker"})
            states.update(app="exited", worker="exited")
            self.manager.active = []
            self.manager.events.append("stop")
            return b""

        with patch.object(self.manager, "running_services", m.Manager.running_services.__get__(self.manager)), \
                patch.object(m, "run", command), contextlib.redirect_stdout(io.StringIO()):
            self.manager.apply_restore(self.manager.apps()["demo"], payload, info, False)
        self.assertLess(self.manager.events.index("stop"), self.manager.events.index("import"))
        self.assertEqual(self.manager.active, ["app", "worker"])

    def test_paused_container_refuses_restore_before_stopping_or_writing(self):
        path = self.create()
        payload, info = self.extract(path)

        def command(argv, **kwargs):
            if "ps" in argv:
                return b"paused-app\n"
            self.assertEqual(argv[1], "inspect")
            return json.dumps({"State": {"Running": True, "Paused": True, "Status": "paused"}}).encode()

        with patch.object(self.manager, "running_services", m.Manager.running_services.__get__(self.manager)), \
                patch.object(m, "run", command), self.assertRaisesRegex(m.BackupError, "paused/removing"):
            self.manager.apply_restore(self.manager.apps()["demo"], payload, info, False)
        self.assertNotIn("stop", self.manager.events)
        self.assertNotIn("import", self.manager.events)
        self.assertEqual(list((self.manager.root / "safety").iterdir()), [])

    def test_failed_database_import_leaves_app_stopped_with_safety_archive(self):
        path = self.create()
        payload, info = self.extract(path)
        self.manager.fail_import = True
        with self.docker_stop(), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(m.BackupError):
            self.manager.apply_restore(self.manager.apps()["demo"], payload, info, False)
        self.assertEqual(self.manager.active, [])
        self.assertNotIn("start", self.manager.events)
        self.assertEqual(len(list((self.manager.root / "safety").glob("*.age"))), 1)
        state = m.read_json(next((self.manager.root / "safety").glob("*.json")))
        self.assertEqual(state["phase"], "failed-after-write")

    def test_failed_safety_backup_resumes_unchanged_app(self):
        path = self.create()
        payload, info = self.extract(path)
        self.manager.fail_capture = True
        with self.docker_stop(), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(m.BackupError):
            self.manager.apply_restore(self.manager.apps()["demo"], payload, info, False)
        self.assertEqual(self.manager.active, ["app", "worker"])
        self.assertNotIn("import", self.manager.events)

    def test_failed_health_check_stops_app_again(self):
        path = self.create()
        payload, info = self.extract(path)
        self.manager.fail_health = True
        with self.docker_stop(), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(m.BackupError):
            self.manager.apply_restore(self.manager.apps()["demo"], payload, info, False)
        self.assertEqual(self.manager.active, [])

    def test_previously_stopped_services_stay_stopped(self):
        path = self.create()
        payload, info = self.extract(path)
        self.manager.active = ["app"]
        with self.docker_stop(), contextlib.redirect_stdout(io.StringIO()):
            self.manager.apply_restore(self.manager.apps()["demo"], payload, info, False)
        self.assertEqual(self.manager.active, ["app"])

    def test_lock_prevents_overlapping_operations(self):
        with self.manager.locked():
            with self.assertRaises(m.BackupError), self.manager.locked():
                self.fail("Lock should reject concurrent operation")

    def test_low_disk_space_stops_capture_before_dump(self):
        self.manager.reserve = 10**20
        with self.assertRaises(m.BackupError):
            self.create()
        self.assertNotIn("dump", self.manager.events)

    def test_drive_quota_alert_counts_other_google_storage(self):
        checksum = "a" * 64
        m.write_json(self.manager.root / "state/last-upload.json", {
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "remote": self.manager.remote_path("2026/09/06/test-run"), "sha256": checksum})
        for quota in ({"total": 100, "used": 20, "other": 70, "free": 10},
                      {"total": 100, "used": 20, "other": 70}):
            with self.subTest(quota=quota), patch.object(
                    self.manager, "rclone", side_effect=[checksum.encode(), json.dumps(quota).encode()]), \
                    patch.object(self.manager, "notify") as notify:
                with self.assertRaises(m.BackupError):
                    self.manager.health()
                notify.assert_called_once_with(
                    "Google Drive is at least 80% full; no files will be deleted automatically")

    def test_restore_preserves_private_storage_directory_modes(self):
        os.chmod(self.storage / "uploads", 0o700)
        path = self.create()
        payload, info = self.extract(path)
        with self.docker_stop(), contextlib.redirect_stdout(io.StringIO()):
            self.manager.apply_restore(self.manager.apps()["demo"], payload, info, False)
        self.assertEqual((self.storage / "uploads").stat().st_mode & 0o777, 0o700)

    def test_public_and_private_directory_modes_survive_cli_umask(self):
        os.chmod(self.storage, 0o755)
        os.chmod(self.storage / "uploads", 0o755)
        (self.storage / "private").mkdir(mode=0o700)
        previous_umask = os.umask(0o077)
        try:
            path = self.create()
            payload, info = self.extract(path)
            self.assertEqual(info["directories"]["storage"], 0o755)
            self.assertEqual(info["directories"]["storage/uploads"], 0o755)
            self.assertEqual(info["directories"]["storage/private"], 0o700)
            with self.docker_stop(), contextlib.redirect_stdout(io.StringIO()):
                self.manager.apply_restore(self.manager.apps()["demo"], payload, info, False)
        finally:
            os.umask(previous_umask)
        self.assertEqual(self.storage.stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.storage / "uploads").stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.storage / "private").stat().st_mode & 0o777, 0o700)

    def test_with_config_is_explicit_and_restores_only_app_configuration(self):
        path = self.create()
        payload, info = self.extract(path)
        (self.infra / "apps/demo/.env").write_text("CURRENT_CONFIG=yes\n")
        with self.docker_stop(), contextlib.redirect_stdout(io.StringIO()):
            self.manager.apply_restore(self.manager.apps()["demo"], payload, info, True)
        self.assertEqual((self.infra / "apps/demo/.env").read_text(), "DB_PASSWORD=synthetic-only\n")
        self.assertEqual((self.infra / "apps/demo/.env").stat().st_mode & 0o777, 0o600)

    def test_config_restore_rejects_database_mount_and_image_drift(self):
        path = self.create()
        payload, info = self.extract(path)
        base = {"name": "demo", "services": {"app": {"image": "example:latest",
                "environment": {"DB_HOST": "mysql", "DB_DATABASE": "demo"},
                "volumes": [{"type": "bind", "source": str(self.storage), "target": "/app/storage"}]}}}
        for change in ("database", "mount", "image", "service"):
            with self.subTest(change=change):
                proposed = json.loads(json.dumps(base))
                if change == "database":
                    proposed["services"]["app"]["environment"]["DB_DATABASE"] = "another_app"
                elif change == "mount":
                    proposed["services"]["app"]["volumes"][0]["source"] = "/opt/volumes/apps/another-app/storage"
                elif change == "service":
                    proposed["services"]["unexpected-worker"] = {"image": "example:latest"}
                responses = [json.dumps(base).encode(), json.dumps(proposed).encode()]
                if change == "image":
                    responses.append(b"sha256:unexpected-new-image\n")
                with patch.object(m, "run", side_effect=responses), self.assertRaises(m.BackupError):
                    self.manager.validate_config_restore(self.manager.apps()["demo"], payload,
                                                         {"app": "sha256:fixture-image"})
                self.assertNotIn("stop", self.manager.events)
                self.assertNotIn("import", self.manager.events)

    def test_config_restore_keeps_project_and_pins_verified_image(self):
        path = self.create()
        payload, info = self.extract(path)
        model = {"name": "demo", "services": {"app": {"image": "example:latest",
                 "environment": {"DB_HOST": "mysql", "DB_DATABASE": "demo", "APP_DEBUG": "false"}}}}
        proposed = json.loads(json.dumps(model))
        proposed["services"]["app"]["environment"]["APP_DEBUG"] = "true"

        def command(argv, **kwargs):
            if argv[1] == "image":
                return b"sha256:fixture-image\n"
            if argv[1] == "inspect":
                return b'{"Running":true,"Health":{"Status":"healthy"}}'
            self.assertEqual(argv[argv.index("--project-name") + 1], "demo")
            if "config" in argv:
                return json.dumps(model if str(self.infra / "apps/demo") in argv else proposed).encode()
            if "up" in argv:
                override = Path(argv[argv.index("up") - 1])
                self.assertEqual(m.read_json(override)["services"]["app"]["image"], "sha256:fixture-image")
                self.assertIn("--no-deps", argv)
                return b""
            if "ps" in argv:
                return b"fixture-container\n"
            self.fail(f"Unexpected Docker operation: {argv[1]}")

        with patch.object(m, "run", command):
            images = self.manager.validate_config_restore(self.manager.apps()["demo"], payload,
                                                         {"app": "sha256:fixture-image"})
            m.Manager.start_and_check(self.manager, "demo", ["app"], True, images)

    def test_verify_only_does_not_stop_or_replace_data(self):
        self.create()
        args = argparse.Namespace(app="demo", file=None, source="local", run="latest",
                                  identity=str(self.identity), allow_image_mismatch=False,
                                  with_config=False, verify_only=True)
        with contextlib.redirect_stdout(io.StringIO()):
            self.manager.restore(args)
        self.assertNotIn("stop", self.manager.events)
        self.assertNotIn("import", self.manager.events)
        self.assertEqual(list((self.manager.root / "safety").iterdir()), [])

    def test_image_mismatch_is_rejected_before_stopping_app(self):
        self.create()
        args = argparse.Namespace(app="demo", file=None, source="local", run="latest",
                                  identity=str(self.identity), allow_image_mismatch=False,
                                  with_config=False, verify_only=True)
        with patch.object(self.manager, "images", return_value={"app": "changed"}), self.assertRaises(m.BackupError):
            self.manager.restore(args)
        self.assertNotIn("stop", self.manager.events)

    def test_live_restore_requires_typed_confirmation(self):
        self.create()
        args = argparse.Namespace(app="demo", file=None, source="local", run="latest",
                                  identity=str(self.identity), allow_image_mismatch=False,
                                  with_config=False, verify_only=False)
        with patch.object(m.sys.stdin, "isatty", return_value=True), patch("builtins.input", return_value="no"), \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(m.BackupError):
            self.manager.restore(args)
        self.assertNotIn("stop", self.manager.events)

    def test_definer_rewrite_does_not_modify_insert_data(self):
        samples = [b"CREATE DEFINER=`root`@`localhost` PROCEDURE p() SELECT 1;\n",
                   b"/*!50013 DEFINER=`root`@`%` SQL SECURITY DEFINER */\n",
                   b"/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`%`*/ /*!50003 TRIGGER t ... */\n"]
        for line in samples:
            self.assertNotIn(b"`root`@", m.DEFINER.sub(rb"\1", line))
        data = b"INSERT INTO sample VALUES ('DEFINER=`root`@`localhost`');\n"
        self.assertEqual(m.DEFINER.sub(rb"\1", data), data)

    def test_immutable_upload_never_overwrites_existing_remote_archive(self):
        path = self.create()
        self.upload()
        remote_archive = next(self.drive.rglob("*.age"))
        remote_archive.write_bytes(b"existing conflicting archive")
        (path / ".uploaded.json").unlink()
        with self.assertRaises(m.BackupError):
            self.upload()
        self.assertEqual(remote_archive.read_bytes(), b"existing conflicting archive")

    def test_prune_refuses_to_remove_local_archive_if_remote_was_lost(self):
        for _ in range(3):
            self.create()
            # Prevent cleanup until all three have been uploaded.
            with patch.object(self.manager, "prune_local"):
                self.upload()
        oldest = self.manager.local_sets()[-1].parent
        info = m.read_json(oldest / "manifest.json")
        (self.drive / "test-vps" / info["path"] / "apps" / info["apps"]["demo"]["file"]).unlink()
        with self.assertRaises(m.BackupError):
            self.manager.prune_local()
        self.assertTrue(oldest.exists())


if __name__ == "__main__":
    unittest.main()
