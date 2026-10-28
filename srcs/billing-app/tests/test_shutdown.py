"""Unit tests for the billing consumer's shutdown ordering and ack policy.

Dependency-free on purpose (like tests/test_validation.py): `pika` and
`app.orders` are stubbed in sys.modules before app/consume_queue.py is loaded,
so the REAL `start_consuming()` can be driven on a bare host with no broker, no
database and no container. `app.validation` is loaded from its file so the real
coercion rules apply.

What these tests pin:

  * a shutdown request can never leave the consumer blocked in
    `start_consuming()`, which is what produced exit 137 after a SIGTERM landed
    in the window between the AMQP channel being opened and the shutdown
    watcher being created;
  * the watcher exists BEFORE the first connection attempt, so no connection is
    ever live without one;
  * the ack/nack policy is unchanged: a committed order is acked, a failed
    insert is nacked with requeue=True after the redelivery backoff, a poison
    payload is acked and discarded, and an escaping exception still nacks;
  * the `connected_event` that /ready reads is set only while the consumer is
    registered with the broker, and is cleared the moment the connection drops
    or the consumer stops.
"""

import importlib.util
import logging
import os
import sys
import threading
import time
import types
import unittest

logging.disable(logging.CRITICAL)  # the module under test logs a lot; keep output clean

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "app", "consume_queue.py",
)
_VALIDATION_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "app", "validation.py",
)


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --- stubs -------------------------------------------------------------------

class FakeOrder:
    """Stand-in for app.orders.Order: records the fields it was built with."""

    def __init__(self, **kwargs):
        self.id = None
        self.__dict__.update(kwargs)


class FakeSession:
    """Records the transaction calls _handle_message makes."""

    def __init__(self, factory_state):
        self._state = factory_state

    def add(self, obj):
        self._state["added"].append(obj)

    def flush(self):
        # SQLAlchemy populates an autoincrement PK on INSERT, which flush()
        # emits -- and a primary key is never expired by commit(), so reading it
        # straight after flush is safe on a detached instance. The production
        # code depends on exactly that, so the double has to model it.
        obj = self._state["added"][-1] if self._state["added"] else None
        if obj is not None and obj.id is None:
            obj.id = 42

    def commit(self):
        if self._state["commit_error"] is not None:
            raise self._state["commit_error"]
        obj = self._state["added"][-1]
        if obj.id is None:
            obj.id = 42

    def rollback(self):
        self._state["rollbacks"] += 1

    def close(self):
        self._state["closed"] += 1


class FakeMethod:
    def __init__(self, delivery_tag=1):
        self.delivery_tag = delivery_tag


class FakeChannel:
    """Records broker calls; `start_consuming()` blocks like the AMQP read does."""

    def __init__(self, state, hook_after_consume=None, consume_errors=None):
        self.state = state
        self.hook_after_consume = hook_after_consume
        self.consume_errors = consume_errors
        self.acks = []
        self.nacks = []
        self.prefetch = None
        self.consuming = threading.Event()
        self.stopped = threading.Event()

    def queue_declare(self, queue, durable=False):
        self.state["declared"].append((queue, durable))

    def basic_qos(self, prefetch_count=None):
        self.prefetch = prefetch_count

    def basic_consume(self, queue, on_message_callback, auto_ack=False):
        self.state["consume_callback"] = on_message_callback
        self.state["auto_ack"] = auto_ack
        if self.hook_after_consume is not None:
            # The race window: the real SIGTERM landed here, between the channel
            # being set up and the shutdown watcher existing.
            self.hook_after_consume()

    def start_consuming(self):
        self.state["start_consuming_calls"] += 1
        if self.consume_errors:
            # The broker dropping the connection mid-consume: pika raises out of
            # the blocking read.
            raise self.consume_errors.pop(0)
        self.consuming.set()
        # This is the socket read that must be woken by stop_consuming().
        self.stopped.wait(10)

    def stop_consuming(self):
        self.state["stop_consuming_calls"] += 1
        self.stopped.set()

    def basic_ack(self, delivery_tag):
        self.acks.append(delivery_tag)

    def basic_nack(self, delivery_tag, requeue=False):
        self.nacks.append((delivery_tag, requeue))


class FakeConnection:
    def __init__(self, state, hook_after_consume=None, channel_error=None, consume_errors=None):
        self.state = state
        self.hook_after_consume = hook_after_consume
        self.channel_error = channel_error
        self.consume_errors = consume_errors
        self.is_open = True
        self.closed = False
        self.channel_instance = None

    def channel(self):
        if self.channel_error is not None:
            raise self.channel_error
        self.channel_instance = FakeChannel(self.state, self.hook_after_consume, self.consume_errors)
        return self.channel_instance

    def add_callback_threadsafe(self, callback):
        # pika queues this for the ioloop; the fake runs it on the "ioloop"
        # thread, which is what unblocks the fake start_consuming().
        self.state["callbacks_threadsafe"] += 1
        callback()

    def close(self):
        self.closed = True
        self.is_open = False


def _build_consume_queue(new_state):
    """Load a fresh copy of consume_queue with fake pika/orders wired in."""
    state = {
        "connections": [],
        "declared": [],
        "acks": [],
        "nacks": [],
        "watcher_alive_at_connect": [],
        "start_consuming_calls": 0,
        "stop_consuming_calls": 0,
        "callbacks_threadsafe": 0,
        "consume_callback": None,
        "auto_ack": None,
        "added": [],
        "rollbacks": 0,
        "closed": 0,
        "commit_error": None,
    }
    new_state.update(state)

    pika_stub = types.ModuleType("pika")

    class AMQPError(Exception):
        pass

    pika_stub.exceptions = types.SimpleNamespace(
        AMQPConnectionError=type("AMQPConnectionError", (AMQPError,), {}),
        AMQPChannelError=type("AMQPChannelError", (AMQPError,), {}),
    )
    pika_stub.PlainCredentials = lambda user, password: ("creds", user)
    # A real class, not a function: `ssl_options_for()` annotates its return as
    # `pika.SSLOptions | None`, which is evaluated at def time.
    pika_stub.SSLOptions = type("SSLOptions", (), {})

    def connection_parameters(**kwargs):
        return dict(kwargs)

    pika_stub.ConnectionParameters = connection_parameters

    def blocking_connection(parameters):
        # Ordering invariant under test: is the shutdown watcher already alive
        # when the connection attempt starts? The old code created the watcher
        # per connection, AFTER this point.
        state["watcher_alive_at_connect"].append(
            any(t.name == "BillingQueueShutdownWatcher" and t.is_alive()
                for t in threading.enumerate())
        )
        conn = FakeConnection(
            state,
            hook_after_consume=new_state.get("hook_after_consume"),
            channel_error=new_state.get("channel_error"),
            # One shared list: each start_consuming() call pops the next error,
            # so a test can fail the first connection and let the next succeed.
            consume_errors=new_state.get("consume_errors"),
        )
        state["connections"].append(conn)
        return conn

    pika_stub.BlockingConnection = blocking_connection

    orders_stub = types.ModuleType("app.orders")
    orders_stub.Order = FakeOrder

    validation = _load_module("validation_under_test", _VALIDATION_PATH)
    validation_stub = types.ModuleType("app.validation")
    validation_stub.InvalidOrderError = validation.InvalidOrderError
    validation_stub.coerce_order_payload = validation.coerce_order_payload

    saved = {k: sys.modules.get(k) for k in ("pika", "app", "app.orders", "app.validation")}
    app_stub = types.ModuleType("app")
    sys.modules["pika"] = pika_stub
    sys.modules["app"] = app_stub
    sys.modules["app.orders"] = orders_stub
    sys.modules["app.validation"] = validation_stub
    try:
        module = _load_module("consume_queue_under_test", _MODULE_PATH)
        module.__dict__["state"] = state
    finally:
        for name, value in saved.items():
            if value is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = value
    return module, state


def _run_consumer(module, state, stop_event, timeout=10):
    """Run start_consuming() in a thread; return it so the caller can join."""
    thread = threading.Thread(
        target=module.start_consuming,
        args=(lambda: FakeSession(state), stop_event),
        daemon=True,
        name="ConsumerUnderTest",
    )
    thread.start()
    thread.join(timeout)
    return thread


def _wait_for(predicate, what, timeout=10):
    """Poll until `predicate()` is true; fails the caller's test on timeout."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    raise AssertionError(f"timed out after {timeout}s waiting for: {what}")


class ShutdownOrderingTest(unittest.TestCase):
    def setUp(self):
        self.stop_event = threading.Event()
        for name in ("RABBITMQ_USER", "RABBITMQ_PASSWORD"):
            os.environ[name] = "test-user" if name.endswith("USER") else "test-password"
        os.environ["RABBITMQ_HOST"] = "broker.invalid"
        os.environ["RABBITMQ_PORT"] = "5672"      # plaintext: no SSLOptions needed
        os.environ["RABBITMQ_TLS"] = ""
        os.environ["RABBITMQ_QUEUE"] = "billing_queue"

    def test_watcher_exists_before_the_first_connection_attempt(self):
        """The invariant the old code violated: no unwatched connection, ever.

        With the watcher created inside the loop, this records False on the first
        attempt and the process has no way to be told to stop until after the
        blocking call is entered.
        """
        module, state = _build_consume_queue({})
        worker = _run_consumer(module, state, self.stop_event, timeout=2)
        self.stop_event.set()
        worker.join(5)

        self.assertTrue(
            state["watcher_alive_at_connect"],
            "no connection attempt was recorded",
        )
        self.assertTrue(
            all(state["watcher_alive_at_connect"]),
            f"watcher was not alive for every connection attempt: {state['watcher_alive_at_connect']}",
        )

    def test_stop_during_the_race_window_never_blocks_in_start_consuming(self):
        """SIGTERM arriving between basic_consume and the blocking call.

        This is the reported race: `stop_event` is set at exactly the point the
        old code had no watcher yet. The consumer must return without ever
        parking in `start_consuming()`.
        """
        module, state = _build_consume_queue({
            "hook_after_consume": self.stop_event.set,
        })
        worker = _run_consumer(module, state, self.stop_event, timeout=5)

        self.assertFalse(worker.is_alive(), "consumer is still blocked in start_consuming()")
        self.assertEqual(state["start_consuming_calls"], 0)
        self.assertFalse(worker.is_alive())

    def test_stop_while_blocked_in_start_consuming_unblocks_it(self):
        """Once parked in the AMQP read, the watcher still stops the consumer."""
        module, state = _build_consume_queue({})
        worker = threading.Thread(
            target=module.start_consuming,
            args=(lambda: FakeSession(state), self.stop_event),
            daemon=True,
            name="ConsumerUnderTest",
        )
        worker.start()
        _wait_for(lambda: state["start_consuming_calls"] == 1, "the consumer to enter start_consuming()")
        self.assertTrue(worker.is_alive(), "consumer should be parked in the AMQP read")
        self.assertEqual(state["stop_consuming_calls"], 0)

        self.stop_event.set()
        worker.join(10)

        self.assertFalse(worker.is_alive(), "consumer did not stop after stop_event was set")
        self.assertEqual(state["stop_consuming_calls"], 1)
        self.assertEqual(state["callbacks_threadsafe"], 1)
        self.assertTrue(state["connections"][0].closed, "the AMQP connection was not closed")

    def test_pre_set_stop_event_returns_without_connecting(self):
        module, state = _build_consume_queue({})
        self.stop_event.set()
        worker = _run_consumer(module, state, self.stop_event, timeout=5)

        self.assertFalse(worker.is_alive())
        self.assertEqual(state["connections"], [])
        self.assertEqual(state["start_consuming_calls"], 0)


class AckPolicyTest(unittest.TestCase):
    """The at-least-once guarantees must survive the shutdown reordering."""

    def setUp(self):
        self.stop_event = threading.Event()
        for name, value in (("RABBITMQ_USER", "u"), ("RABBITMQ_PASSWORD", "p")):
            os.environ[name] = value
        os.environ["RABBITMQ_HOST"] = "broker.invalid"
        os.environ["RABBITMQ_PORT"] = "5672"
        self.module, self.state = _build_consume_queue({})
        # The retry/backoff sleeps are wall-clock; replace them so the test does
        # not spend 10s proving a DB outage is throttled. The CALLS are asserted.
        self.sleeps = []
        self.module.time = types.SimpleNamespace(sleep=self.sleeps.append)

    def _deliver(self, payload, commit_error=None):
        """Start the consumer, hand it one delivery, then shut it down."""
        self.state["commit_error"] = commit_error
        worker = threading.Thread(
            target=self.module.start_consuming,
            args=(lambda: FakeSession(self.state), self.stop_event),
            daemon=True,
            name="ConsumerUnderTest",
        )
        worker.start()
        _wait_for(
            lambda: self.state["consume_callback"] is not None,
            "basic_consume() to register the delivery callback",
        )
        channel = self.state["connections"][0].channel_instance
        raw = payload if isinstance(payload, (bytes, bytearray)) else payload.encode()
        # Called directly, exactly as pika's ioloop would from the AMQP socket:
        # callback(channel, method, properties, body).
        self.state["consume_callback"](channel, FakeMethod(), None, raw)
        self.stop_event.set()
        worker.join(10)
        self.assertFalse(worker.is_alive(), "consumer did not stop after the delivery")
        return channel

    def test_committed_order_is_acked_and_prefetch_is_one(self):
        channel = self._deliver('{"user_id":"20","number_of_items":"2","total_amount":"10.50"}')
        self.assertEqual(channel.acks, [1])
        self.assertEqual(channel.nacks, [])
        self.assertEqual(channel.prefetch, 1)
        self.assertEqual(channel.state["auto_ack"], False)

    def test_failed_insert_is_nacked_with_requeue_after_the_backoff(self):
        channel = self._deliver(
            '{"user_id":"20","number_of_items":"2","total_amount":"10.50"}',
            commit_error=RuntimeError("database is down"),
        )
        self.assertEqual(channel.acks, [], "a failed insert must never be acknowledged")
        self.assertEqual(channel.nacks, [(1, True)], "expected basic_nack(requeue=True)")
        self.assertEqual(self.sleeps[-1], self.module.REDELIVERY_BACKOFF_SECONDS)
        self.assertEqual(self.state["rollbacks"], 5)

    def test_poison_payload_is_acked_and_discarded(self):
        channel = self._deliver("this is not json")
        self.assertEqual(channel.acks, [1])
        self.assertEqual(channel.nacks, [])

    def test_invalid_fields_are_acked_and_discarded(self):
        channel = self._deliver('{"user_id":"","number_of_items":"1","total_amount":"1.00"}')
        self.assertEqual(channel.acks, [1])
        self.assertEqual(channel.nacks, [])

    def test_over_long_user_id_is_discarded_not_requeued(self):
        """The queue-unblocking case.

        Requeueing a message that can never be persisted would redeliver it
        forever and, with prefetch_count=1, block every order behind it. It must
        be acknowledged and dropped like any other poison payload - while a real
        database failure still nacks and requeues (see the test above).
        """
        channel = self._deliver(
            '{"user_id":"' + "x" * 900_000 + '","number_of_items":"1","total_amount":"1.00"}'
        )
        self.assertEqual(channel.acks, [1], "an unpersistable message must be discarded")
        self.assertEqual(channel.nacks, [], "an unpersistable message must not be requeued forever")
        self.assertEqual(self.state["added"], [])


class ConsumerConnectedEventTest(unittest.TestCase):
    """/ready reads this Event, so it must follow the broker registration exactly."""

    def setUp(self):
        self.stop_event = threading.Event()
        self.connected = threading.Event()
        for name, value in (("RABBITMQ_USER", "u"), ("RABBITMQ_PASSWORD", "p")):
            os.environ[name] = value
        os.environ["RABBITMQ_HOST"] = "broker.invalid"
        os.environ["RABBITMQ_PORT"] = "5672"
        os.environ["RABBITMQ_TLS"] = ""

    def _start(self, module, state):
        worker = threading.Thread(
            target=module.start_consuming,
            args=(lambda: FakeSession(state), self.stop_event, self.connected),
            daemon=True,
            name="ConsumerUnderTest",
        )
        worker.start()
        return worker

    def test_set_while_consuming_and_cleared_on_shutdown(self):
        module, state = _build_consume_queue({})
        worker = self._start(module, state)
        _wait_for(lambda: state["start_consuming_calls"] == 1, "the consumer to enter start_consuming()")
        self.assertTrue(self.connected.is_set(), "a registered consumer must report connected")

        self.stop_event.set()
        worker.join(10)

        self.assertFalse(worker.is_alive(), "consumer did not stop after stop_event was set")
        self.assertFalse(self.connected.is_set(), "a stopped consumer must not report connected")

    def test_cleared_before_the_retry_sleep_when_the_broker_drops_the_connection(self):
        """A lost broker must show in /ready at once, not after the 3 s retry pause."""
        errors = []
        module, state = _build_consume_queue({"consume_errors": errors})
        errors.append(module.pika.exceptions.AMQPConnectionError("connection lost"))
        seen_during_retry_sleep = []
        module.time = types.SimpleNamespace(
            sleep=lambda _seconds: seen_during_retry_sleep.append(self.connected.is_set())
        )

        worker = self._start(module, state)
        _wait_for(lambda: state["start_consuming_calls"] == 2, "the consumer to reconnect")
        self.assertEqual(seen_during_retry_sleep, [False], "the Event stayed set while the consumer was down")
        self.assertTrue(self.connected.is_set(), "the reconnected consumer must report connected again")

        self.stop_event.set()
        worker.join(10)

        self.assertFalse(worker.is_alive())
        self.assertFalse(self.connected.is_set())

    def test_never_set_when_shutdown_wins_the_race(self):
        module, state = _build_consume_queue({"hook_after_consume": self.stop_event.set})
        worker = self._start(module, state)
        worker.join(5)

        self.assertFalse(worker.is_alive())
        self.assertEqual(state["start_consuming_calls"], 0)
        self.assertFalse(self.connected.is_set())


if __name__ == "__main__":
    unittest.main()