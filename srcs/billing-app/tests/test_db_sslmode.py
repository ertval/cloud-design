"""Unit tests for the sslmode billing-app puts on its database URL.

Dependency-free on purpose, like the other suites here: `flask`, `sqlalchemy`
and `app.orders` are stubbed in sys.modules before app/__init__.py is loaded.
The stub `URL.create` records its keyword arguments, so the tests read the
exact `query` the real `create_app()` hands to SQLAlchemy (and so to libpq).

What these tests pin:

  * with DB_SSLMODE unset or empty the URL carries sslmode=require, so a
    session to RDS is TLS or it fails;
  * DB_SSLMODE=prefer (the local compose and k3d value) is passed through;
  * case and surrounding spaces do not matter;
  * an unknown value falls back to require, never to a weaker mode.
"""

import contextlib
import importlib.util
import logging
import os
import sys
import types
import unittest

logging.disable(logging.CRITICAL)

_APP_INIT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "app", "__init__.py",
)


class FakeFlask:
    def __init__(self, import_name):
        pass

    def route(self, rule, methods=None):
        return lambda view: view


class FakeConnection:
    def execute(self, _statement):
        pass


class FakeEngine:
    def connect(self):
        return contextlib.nullcontext(FakeConnection())


def _build_app_module():
    """Load a fresh app/__init__.py; return it and the list of URL.create kwargs."""
    url_calls = []

    flask_stub = types.ModuleType("flask")
    flask_stub.Flask = FakeFlask
    flask_stub.jsonify = dict

    sqlalchemy_stub = types.ModuleType("sqlalchemy")
    sqlalchemy_stub.text = str
    engine_stub = types.ModuleType("sqlalchemy.engine")
    engine_stub.URL = types.SimpleNamespace(
        create=lambda *args, **kwargs: url_calls.append(kwargs) or ("url", kwargs)
    )
    exc_stub = types.ModuleType("sqlalchemy.exc")
    exc_stub.InterfaceError = type("InterfaceError", (Exception,), {})
    exc_stub.OperationalError = type("OperationalError", (Exception,), {})

    orders_stub = types.ModuleType("app.orders")
    orders_stub.Order = type("Order", (), {})
    orders_stub.get_db_engine = lambda _url: FakeEngine()
    orders_stub.init_db = lambda _engine: (lambda: None)

    stubs = {
        "flask": flask_stub,
        "sqlalchemy": sqlalchemy_stub,
        "sqlalchemy.engine": engine_stub,
        "sqlalchemy.exc": exc_stub,
        "app": types.ModuleType("app"),
        "app.orders": orders_stub,
    }
    saved = {name: sys.modules.get(name) for name in stubs}
    sys.modules.update(stubs)
    try:
        spec = importlib.util.spec_from_file_location("billing_app_sslmode_under_test", _APP_INIT_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        for name, value in saved.items():
            if value is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = value
    return module, url_calls


class DatabaseSslmodeTest(unittest.TestCase):
    def setUp(self):
        os.environ["BILLING_DB_USER"] = "u"
        os.environ["BILLING_DB_PASSWORD"] = "p"
        self._saved = os.environ.pop("DB_SSLMODE", None)
        self.module, self.url_calls = _build_app_module()

    def tearDown(self):
        os.environ.pop("DB_SSLMODE", None)
        if self._saved is not None:
            os.environ["DB_SSLMODE"] = self._saved

    def _sslmode_in_url(self):
        self.module.create_app()
        self.assertEqual(len(self.url_calls), 1)
        return self.url_calls[0]["query"]["sslmode"]

    def test_unset_means_require(self):
        self.assertEqual(self._sslmode_in_url(), "require")

    def test_empty_means_require(self):
        # Docker Compose turns an undefined ${VAR} into "", not into "unset".
        os.environ["DB_SSLMODE"] = ""
        self.assertEqual(self._sslmode_in_url(), "require")

    def test_local_prefer_is_passed_through(self):
        os.environ["DB_SSLMODE"] = "prefer"
        self.assertEqual(self._sslmode_in_url(), "prefer")

    def test_case_and_spaces_do_not_matter(self):
        os.environ["DB_SSLMODE"] = " Verify-Full "
        self.assertEqual(self._sslmode_in_url(), "verify-full")

    def test_unknown_value_falls_back_to_require(self):
        os.environ["DB_SSLMODE"] = "required"
        self.assertEqual(self._sslmode_in_url(), "require")


if __name__ == "__main__":
    unittest.main()
