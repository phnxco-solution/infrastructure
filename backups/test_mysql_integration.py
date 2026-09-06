"""Opt-in real MySQL 8.4 restoration tests against a labeled disposable container.

Never point this at an application database. See README for fixture startup.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from test_manager import m


@unittest.skipUnless(os.environ.get("BACKUP_TEST_MYSQL_CONTAINER"), "Requires the disposable MySQL fixture")
class MySQLIntegrationTests(unittest.TestCase):
    def setUp(self):
        container = os.environ["BACKUP_TEST_MYSQL_CONTAINER"]
        self.assertTrue(container.startswith("backup-test-"), "Refusing a non-test container")
        label = subprocess.check_output(["docker", "inspect", "--format",
                                         '{{index .Config.Labels "infrastructure.backup.test"}}', container]).decode().strip()
        self.assertEqual(label, "true", "Container must be explicitly labeled as a disposable backup test")
        self.temp = tempfile.TemporaryDirectory(prefix="backup-mysql-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        identity = self.base / "identity"
        subprocess.run(["age-keygen", "-o", str(identity)], check=True, capture_output=True)
        recipient = subprocess.check_output(["age-keygen", "-y", str(identity)]).decode().strip()
        self.identity = identity
        self.manager = m.Manager({"infrastructure_root": str(self.base / "infra"),
                                  "volumes_root": str(self.base / "volumes"),
                                  "backup_root": str(self.base / "backups"),
                                  "mysql_container": container, "minimum_free_bytes": 0,
                                  "age_recipients": [recipient]})
        self.manager.init_local()
        (self.base / "volumes/demo/storage").mkdir(parents=True)
        (self.base / "volumes/demo/storage/file.txt").write_text("fixture upload")
        (self.base / "infra/apps/demo").mkdir(parents=True)
        self.app = {"name": "demo", "database": "backup_restore_test", "owner": [82, 82],
                    "config_files": [], "excludes": []}
        self.manager.sql("DROP DATABASE IF EXISTS backup_restore_test; DROP DATABASE IF EXISTS backupXrestoreXtest; "
                         "CREATE DATABASE backup_restore_test; CREATE DATABASE backupXrestoreXtest; "
                         "CREATE TABLE backupXrestoreXtest.untouched (id INT); INSERT INTO backupXrestoreXtest.untouched VALUES (77); "
                         "CREATE TABLE backup_restore_test.sample (id INT PRIMARY KEY, payload BLOB); "
                         "INSERT INTO backup_restore_test.sample VALUES (42, UNHEX('00FF010A')); "
                         "CREATE VIEW backup_restore_test.example_view AS SELECT * FROM backup_restore_test.sample; "
                         "CREATE PROCEDURE backup_restore_test.example_procedure() SELECT COUNT(*) FROM backup_restore_test.sample;\n")

    def test_real_dump_encryption_restore_and_stored_definers(self):
        archive = self.base / "backup.age"
        run_id = "20260906T010000Z-a7b219e3"
        with patch.object(self.manager, "images", return_value={}):
            self.manager.capture(self.app, archive, run_id)
        payload = self.base / "payload"
        info = self.manager.extract(archive, self.identity, payload, "demo", run_id)
        self.manager.sql("DELETE FROM backup_restore_test.sample;\n")
        self.manager.import_database(self.app, payload, info["schema"])
        self.assertEqual(self.manager.sql("SELECT id,HEX(payload) FROM backup_restore_test.example_view;\n").strip(), b"42\t00FF010A")
        self.assertEqual(self.manager.sql("CALL backup_restore_test.example_procedure();\n").strip(), b"1")
        self.assertEqual(self.manager.sql("SELECT id FROM backupXrestoreXtest.untouched;\n").strip(), b"77")
        self.assertEqual(self.manager.sql("SELECT account_locked FROM mysql.user WHERE user IN "
                                         "(SELECT SUBSTRING_INDEX(DEFINER,'@',1) FROM information_schema.VIEWS "
                                         "WHERE TABLE_SCHEMA='backup_restore_test');\n").strip(), b"Y")

    def test_archive_sql_cannot_modify_another_database(self):
        payload = self.base / "bad-payload"
        payload.mkdir()
        # This name matches the target if underscores accidentally act as wildcards.
        (payload / "database.sql").write_text("DROP DATABASE backupXrestoreXtest;\n")
        original = self.manager.sql("SELECT @@partial_revokes;\n").decode().strip()
        try:
            for enabled in (0, 1):
                with self.subTest(partial_revokes=enabled):
                    self.manager.sql(f"SET GLOBAL partial_revokes={enabled};\n")
                    with self.assertRaises(m.BackupError):
                        self.manager.import_database(self.app, payload, ["utf8mb4", "utf8mb4_unicode_ci"])
                    self.assertEqual(self.manager.sql("SELECT id FROM backupXrestoreXtest.untouched;\n").strip(), b"77")
        finally:
            self.manager.sql(f"SET GLOBAL partial_revokes={original};\n")


if __name__ == "__main__":
    unittest.main()
