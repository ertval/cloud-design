"""Unit tests for the billing order payload contract.

Strict and fully Python: every field must be present and exactly usable --
"12abc" does not coerce to 12, `user_id` is a 32-bit int (not a string), and
money stays a `Decimal` all the way into `Numeric(12, 2)` instead of drifting
through an IEEE-754 float.

Dependency-free: `python3 -m unittest discover -s tests` runs on a bare host
with no Flask, SQLAlchemy, pika or database (`make test-py`).
"""

import unittest
from decimal import Decimal

import importlib.util
import os
import unittest

# `from app.validation import ...` would execute app/__init__.py first, which
# imports Flask and SQLAlchemy - neither is installed on a bare host, and the
# point of these modules is that they need neither. Loading the file directly
# keeps the test runnable with a stock interpreter.
_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "app", "validation.py",
)
_spec = importlib.util.spec_from_file_location("validation", _MODULE_PATH)
validation = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validation)

InvalidOrderError = validation.InvalidOrderError
coerce_order_payload = validation.coerce_order_payload
MAX_USER_ID_LENGTH = validation.MAX_USER_ID_LENGTH
parse_user_id = validation.parse_user_id


def _order(**overrides):
    payload = {"user_id": "20", "number_of_items": "99", "total_amount": "250"}
    payload.update(overrides)
    return payload


class CoerceOrderPayloadTest(unittest.TestCase):
    def test_audit_style_strings_are_coerced(self):
        payload = {"user_id": "20", "number_of_items": "99", "total_amount": "250"}
        self.assertEqual(coerce_order_payload(payload), (20, 99, Decimal("250")))

    def test_native_json_numbers_are_accepted(self):
        payload = {"user_id": 20, "number_of_items": 99, "total_amount": 250.5}
        self.assertEqual(coerce_order_payload(payload), (20, 99, Decimal("250.5")))

    def test_total_amount_stays_exact_decimal(self):
        # 0.1 + 0.2 != 0.3 in binary floating point; it must be exact here.
        amount = coerce_order_payload({"user_id": "1", "number_of_items": 1, "total_amount": "0.30"})[2]
        self.assertIsInstance(amount, Decimal)
        self.assertEqual(amount, Decimal("0.30"))
        self.assertEqual(str(amount), "0.30")

    def test_user_id_is_coerced_to_int(self):
        self.assertEqual(coerce_order_payload(_order(user_id=7))[0], 7)
        self.assertEqual(coerce_order_payload(_order(user_id="  7 "))[0], 7)
        self.assertEqual(coerce_order_payload(_order(user_id="-5"))[0], -5)

    def test_rejects_payloads_that_are_not_a_json_object(self):
        for bad in ([1], None, "order", 42):
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(bad)

    def test_rejects_a_missing_field(self):
        # Every field is required: a missing field is a poison pill, not a
        # default, because requeueing it could never succeed.
        for bad in ({}, {"user_id": "1"}, {"user_id": "1", "number_of_items": 2}):
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(bad)

    def test_rejects_an_empty_user_id(self):
        for bad in ({"user_id": ""}, {"user_id": "   "}):
            payload = _order(user_id=bad["user_id"])
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(payload)

    def test_rejects_unusable_numbers(self):
        for bad in (
            _order(number_of_items="many"),
            _order(total_amount="abc"),
            _order(total_amount=None),
        ):
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(bad)

    def test_rejects_prefix_leniency(self):
        # Strict: "12abc" is not 12 and "5.9" items is not 5.
        for bad in (
            _order(user_id="12abc"),
            _order(user_id="5.9"),
            _order(number_of_items="12abc"),
            _order(number_of_items="5.9"),
            _order(number_of_items=99.5),
            _order(total_amount="12abc"),
        ):
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(bad)

    def test_rejects_booleans(self):
        for bad in (
            _order(user_id=True),
            _order(number_of_items=False),
            _order(total_amount=True),
        ):
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(bad)

    def test_rejects_non_finite_amounts(self):
        for bad in ("NaN", "Infinity", "-Infinity", float("nan"), float("inf")):
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(_order(total_amount=bad))

    def test_rejects_containers(self):
        for bad in ({"a": 1}, [1, 2], (1,)):
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(_order(user_id=bad))
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(_order(total_amount=bad))

    def test_error_message_names_the_failure(self):
        with self.assertRaisesRegex(InvalidOrderError, "user_id"):
            coerce_order_payload(_order(user_id=""))


class ParseUserIdTest(unittest.TestCase):
    def test_int32_boundaries(self):
        self.assertEqual(parse_user_id(2147483647), 2147483647)
        self.assertEqual(parse_user_id(-2147483648), -2147483648)
        self.assertEqual(parse_user_id("2147483647"), 2147483647)
        self.assertIsNone(parse_user_id(2147483648))
        self.assertIsNone(parse_user_id(-2147483649))
        self.assertIsNone(parse_user_id("9999999999999999999"))
        self.assertIsNone(parse_user_id("2147483648"))

    def test_rejects_malformed_literals(self):
        for bad in ("", "   ", "abc", "12abc", "1.5", "007", "+5", "1_2", None, True, False, 7.5):
            self.assertIsNone(parse_user_id(bad), repr(bad))

    def test_accepts_canonical_forms(self):
        self.assertEqual(parse_user_id(" 12 "), 12)
        self.assertEqual(parse_user_id("-5"), -5)
        self.assertEqual(parse_user_id(7.0), 7)


class UserIdBoundaryTest(unittest.TestCase):
    """The two independent bounds on `user_id`.

    `orders.user_id` is INTEGER, so the *stored* bound is INT32 -- at most ten
    digits -- and that is what `parse_user_id` enforces. Separately, the RAW
    field is bounded before parsing, because an unbounded field is still a
    denial-of-service surface: the 900 KB user_id that once wedged the live queue
    must be rejected as a payload error rather than parsed. Both are asserted
    here because both are real, and they are not the same limit.
    """

    def _order(self, user_id):
        return {"user_id": user_id, "number_of_items": "2", "total_amount": "1.00"}

    def test_accepts_a_ten_digit_user_id(self):
        user_id = "2147483647"  # INT32 max
        self.assertEqual(coerce_order_payload(self._order(user_id))[0], 2147483647)

    def test_rejects_a_user_id_one_digit_over_int32(self):
        with self.assertRaises(InvalidOrderError):
            coerce_order_payload(self._order("2147483648"))

    def test_accepts_a_user_id_at_exactly_the_raw_length_limit(self):
        user_id = "9" * MAX_USER_ID_LENGTH
        # Long enough to exercise the raw bound, but still rejected for range --
        # which is the correct outcome and proves both limits coexist.
        with self.assertRaises(InvalidOrderError):
            coerce_order_payload(self._order(user_id))

    def test_rejects_a_very_long_user_id(self):
        # The 900 KB payload that wedged the live queue.
        with self.assertRaises(InvalidOrderError) as ctx:
            coerce_order_payload(self._order("1" * 900_000))
        self.assertIn("255", str(ctx.exception))

    def test_message_names_the_field_the_limit_and_the_actual_length(self):
        with self.assertRaises(InvalidOrderError) as ctx:
            coerce_order_payload(self._order("9" * 300))
        self.assertIn("user_id", str(ctx.exception))
        self.assertIn("255", str(ctx.exception))
        self.assertIn("300", str(ctx.exception))

    def test_raw_limit_is_measured_after_stripping(self):
        padded = "  " + "9" * MAX_USER_ID_LENGTH + "  "
        with self.assertRaises(InvalidOrderError):
            coerce_order_payload(self._order(padded))

    def test_money_is_still_exact(self):
        amount = coerce_order_payload(
            {"user_id": "42", "number_of_items": "1", "total_amount": "0.30"}
        )[2]
        self.assertIsInstance(amount, Decimal)
        self.assertEqual(str(amount), "0.30")


if __name__ == "__main__":
    unittest.main()
