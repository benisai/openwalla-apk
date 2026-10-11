import unittest
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
    }
    values.update(overrides)
    return SimpleNamespace(**values)


class AuthenticationManagerTest(unittest.TestCase):
    def test_creates_and_validates_session(self) -> None:
        manager = AuthenticationManager(settings())

        self.assertTrue(manager.login("192.0.2.1", "admin", "correct horse").accepted)
        self.assertTrue(manager.valid_session(manager.create_session()))
        self.assertFalse(manager.valid_session("invalid"))

    def test_supports_scrypt_password_hash(self) -> None:
        manager = AuthenticationManager(
            settings(ui_password="", ui_password_hash=create_password_hash("secret"))
        )

        self.assertTrue(manager.login("192.0.2.1", "admin", "secret").accepted)
        self.assertFalse(manager.login("192.0.2.2", "admin", "wrong").accepted)

    def test_bans_address_after_failure_limit(self) -> None:
        manager = AuthenticationManager(settings())

        self.assertEqual(manager.login("192.0.2.1", "admin", "wrong").banned_seconds, 0)
        self.assertEqual(manager.login("192.0.2.1", "admin", "wrong").banned_seconds, 0)
        result = manager.login("192.0.2.1", "admin", "wrong")

        self.assertEqual(result.banned_seconds, 3600)
        self.assertFalse(manager.login("192.0.2.1", "admin", "correct horse").accepted)
        self.assertEqual(len(manager.status()["banned"]), 1)


if __name__ == "__main__":
    unittest.main()
