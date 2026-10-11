import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from app.auth import AuthenticationManager, create_password_hash


def settings(**overrides):
    values = {
        "session_secret": "test-secret",
        "api_token": "",
        "ui_password": "correct horse",
        "ui_password_hash": "",
        "ui_username": "admin",
        "session_hours": 24,
        "auth_window_seconds": 900,
        "auth_max_failures": 3,
        "auth_ban_seconds": 3600,
        "auth_trust_proxy": False,
        "auth_ban_path": Path("/tmp/openwalla-auth-bans-test.json"),
    }
    values.update(overrides)
    return SimpleNamespace(**values)


class AuthenticationManagerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.ban_path = Path(self.tempdir.name) / "bans.json"

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def manager(self, **overrides) -> AuthenticationManager:
        return AuthenticationManager(settings(auth_ban_path=self.ban_path, **overrides))

    def test_creates_and_validates_session(self) -> None:
        manager = self.manager()

        self.assertTrue(manager.login("192.0.2.1", "admin", "correct horse").accepted)
        self.assertTrue(manager.valid_session(manager.create_session()))
        self.assertFalse(manager.valid_session("invalid"))

    def test_supports_scrypt_password_hash(self) -> None:
        manager = self.manager(
            ui_password="", ui_password_hash=create_password_hash("secret")
        )

        self.assertTrue(manager.login("192.0.2.1", "admin", "secret").accepted)
        self.assertFalse(manager.login("192.0.2.2", "admin", "wrong").accepted)

    def test_bans_address_after_failure_limit(self) -> None:
        manager = self.manager()

        self.assertEqual(manager.login("192.0.2.1", "admin", "wrong").banned_seconds, 0)
        self.assertEqual(manager.login("192.0.2.1", "admin", "wrong").banned_seconds, 0)
        result = manager.login("192.0.2.1", "admin", "wrong")

        self.assertEqual(result.banned_seconds, 3600)
        self.assertFalse(manager.login("192.0.2.1", "admin", "correct horse").accepted)
        self.assertEqual(len(manager.status()["banned"]), 1)

    def test_persists_ban_across_manager_restart(self) -> None:
        manager = self.manager()
        for _ in range(3):
            manager.login("198.51.100.7", "admin", "wrong")

        restarted = self.manager()

        result = restarted.login("198.51.100.7", "admin", "correct horse")
        self.assertFalse(result.accepted)
        self.assertGreater(result.banned_seconds, 0)
        self.assertEqual(self.ban_path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
