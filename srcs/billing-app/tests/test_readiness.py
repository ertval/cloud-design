"""Unit tests for billing-app's /ready answer.

Dependency-free on purpose, like tests/test_shutdown.py: `flask`, `sqlalchemy`
and `app.orders` are stubbed in sys.modules before app/__init__.py is loaded, so
the REAL `create_app()` and its /ready view run on a bare host with no Flask, no
database and no broker. The stub Flask records each view by its route and the
stub `jsonify` returns the body dict, so a view returns `(body, status)`.

What these tests pin:

  * /ready is 200 only when the database answers AND the queue consumer is
    registered with the broker; a consumer that has lost the broker gives 503;
  * it reads the consumer state on every call, not once at startup;
  * a database outage is still reported as before, and the body never carries
    the driver message (which names the internal host);
  * without a consumer Event (create_app() on its own) readiness is the database
    alone, exactly as before.
"""

import contextlib
import importlib.util
import logging
import os
import sys
import threading
import types
import unittest

logging.disable(logging.CRITICAL)

_APP_INIT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "app", "__init__.py",
)


class FakeFlask:
    """Stand-in for flask.Flask: keeps each view function under its route."""

    def __init__(self, import_name):
        self.views = {}

    def route(self, rule, methods=None):
        def register(view):
            self.views[rule] = view
            return view
        return register


class FakeDatabase:
    """The one switch the tests flip: is PostgreSQL reachable?"""

    def __init__(self):
        self.down = False

    def execute(self, _statement):
        if self.down:
            # Shaped like the real driver message, host name included, so the
            # tests can prove it never reaches the response body.
            raise ConnectionError('could not translate host name "billing-database"')


class FakeSession:
    def __init__(self, database):
        self._database = database

    def execute(self, statement):
        self._database.execute(statement)

    def close(self):
        pass


class FakeEngine:
    def __init__(self, database):
        self._database = database

    def connect(self):
        return contextlib.nullcontext(FakeSession(self._database))


def _build_app_module():
    """Load a fresh copy of app/__init__.py with fake flask/sqlalchemy/orders."""
    database = FakeDatabase()

    flask_stub = types.ModuleType("flask")
    flask_stub.Flask = FakeFlask
    flask_stub.jsonify = dict

    sqlalchemy_stub = types.ModuleType("sqlalchemy")
    sqlalchemy_stub.text = str
    engine_stub = types.ModuleType("sqlalchemy.engine")
    engine_stub.URL = types.SimpleNamespace(create=lambda *args, **kwargs: ("url", args, kwargs))
    exc_stub = types.ModuleType("sqlalchemy.exc")
    exc_stub.InterfaceError = type("InterfaceError", (Exception,), {})
    exc_stub.OperationalError = type("OperationalError", (Exception,), {})

    orders_stub = types.ModuleType("app.orders")
    orders_stub.Order = type("Order", (), {})
    orders_stub.get_db_engine = lambda _url: FakeEngine(database)
    orders_stub.init_db = lambda _engine: (lambda: FakeSession(database))

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
        spec = importlib.util.spec_from_file_location("billing_app_under_test", _APP_INIT_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        for name, value in saved.items():
            if value is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = value
    return module, database


class ReadinessTest(unittest.TestCase):
    def setUp(self):
        os.environ["BILLING_DB_USER"] = "u"
        os.environ["BILLING_DB_PASSWORD"] = "p"
        self.module, self.database = _build_app_module()
        self.connected = threading.Event()

    def _ready_view(self, consumer_connected):
        app, _ = self.module.create_app(consumer_connected=consumer_connected)
        return app.views["/ready"]

    def test_ready_when_the_database_and_the_consumer_are_up(self):
        self.connected.set()
        body, status = self._ready_view(self.connected)()
        self.assertEqual(status, 200)
        self.assertEqual(body, {"status": "ready", "database": "reachable", "consumer": "connected"})

    def test_not_ready_while_the_consumer_is_disconnected(self):
        body, status = self._ready_view(self.connected)()
        self.assertEqual(status, 503, "a task that consumes nothing must not report ready")
        self.assertEqual(body["status"], "not-ready")
        self.assertEqual(body["database"], "reachable")
        self.assertEqual(body["consumer"], "disconnected")
        self.assertEqual(body["error"], self.module.CONSUMER_UNAVAILABLE_MESSAGE)

    def test_follows_the_live_consumer_state(self):
        ready = self._ready_view(self.connected)
        self.connected.set()
        self.assertEqual(ready()[1], 200)
        self.connected.clear()   # broker connection lost
        self.assertEqual(ready()[1], 503)
        self.connected.set()     # reconnected
        self.assertEqual(ready()[1], 200)

    def test_database_outage_is_reported_without_the_driver_message(self):
        self.connected.set()
        ready = self._ready_view(self.connected)
        self.database.down = True
        body, status = ready()
        self.assertEqual(status, 503)
        self.assertEqual(body["database"], "unreachable")
        self.assertEqual(body["consumer"], "connected")
        self.assertEqual(body["error"], self.module.DATABASE_UNAVAILABLE_MESSAGE)
        self.assertNotIn("billing-database", repr(body))

    def test_without_a_consumer_event_readiness_is_the_database_alone(self):
        ready = self._ready_view(None)
        body, status = ready()
        self.assertEqual(status, 200)
        self.assertEqual(body, {"status": "ready", "database": "reachable"})
        self.database.down = True
        body, status = ready()
        self.assertEqual(status, 503)
        self.assertNotIn("consumer", body)


if __name__ == "__main__":
    unittest.main()
