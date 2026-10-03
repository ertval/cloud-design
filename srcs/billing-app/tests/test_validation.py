"""Unit tests for the billing order payload contract.

The audit posts every numeric field as a JSON *string* (`"99"`, `"250"`), so
coercion is part of the contract rather than defensive coding. These tests pin
that behaviour, above all that money stays a `Decimal` all the way into
`Numeric(12, 2)` instead of drifting through an IEEE-754 float.

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


class CoerceOrderPayloadTest(unittest.TestCase):
    def test_audit_style_strings_are_coerced(self):
        payload = {"user_id": "20", "number_of_items": "99", "total_amount": "250"}
        self.assertEqual(coerce_order_payload(payload), ("20", 99, Decimal("250")))

    def test_native_json_numbers_are_accepted(self):
        payload = {"user_id": 20, "number_of_items": 99, "total_amount": 250.5}
        self.assertEqual(coerce_order_payload(payload), ("20", 99, Decimal("250.5")))

    def test_total_amount_stays_exact_decimal(self):
        # 0.1 + 0.2 != 0.3 in binary floating point; it must be exact here.
        amount = coerce_order_payload({"user_id": "1", "total_amount": "0.30"})[2]
        self.assertIsInstance(amount, Decimal)
        self.assertEqual(amount, Decimal("0.30"))
        self.assertEqual(str(amount), "0.30")

    def test_user_id_is_normalised_to_a_stripped_string(self):
        self.assertEqual(coerce_order_payload({"user_id": 7})[0], "7")
        self.assertEqual(coerce_order_payload({"user_id": "  7 "})[0], "7")

    def test_missing_optional_fields_default(self):
        self.assertEqual(coerce_order_payload({"user_id": "1"}), ("1", 0, Decimal("0.0")))

    def test_rejects_payloads_that_are_not_a_json_object(self):
        for bad in ([1], None, "order", 42):
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(bad)

    def test_rejects_an_empty_user_id(self):
        for bad in ({}, {"user_id": ""}, {"user_id": "   "}):
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(bad)

    def test_rejects_unusable_numbers(self):
        for bad in (
            {"user_id": "1", "number_of_items": "many"},
            {"user_id": "1", "total_amount": "abc"},
            {"user_id": "1", "total_amount": None},
        ):
            with self.assertRaises(InvalidOrderError):
                coerce_order_payload(bad)

    def test_error_message_names_the_failure(self):
        with self.assertRaisesRegex(InvalidOrderError, "user_id"):
            coerce_order_payload({"user_id": ""})


class UserIdLengthBoundaryTest(unittest.TestCase):
    """The VARCHAR(255) boundary on `orders.user_id`.

    An over-long user_id cannot be stored, so leaving it to the database turns
    one such message into an infinite redelivery that blocks the head of the
    queue for every order behind it. It must be rejected as a payload error.
    """

    def test_accepts_a_user_id_of_exactly_the_maximum_length(self):
        user_id = "u" * MAX_USER_ID_LENGTH
        self.assertEqual(
            coerce_order_payload({"user_id": user_id, "total_amount": "1.00"})[0],
            user_id,
        )

    def test_rejects_a_user_id_one_character_over_the_maximum(self):
        with self.assertRaises(InvalidOrderError):
            coerce_order_payload({"user_id": "u" * (MAX_USER_ID_LENGTH + 1)})

    def test_rejects_a_very_long_user_id(self):
        # The 900 KB payload that wedged the live queue.
        with self.assertRaises(InvalidOrderError):
            coerce_order_payload({"user_id": "x" * 900_000})

    def test_message_names_the_field_the_limit_and_the_actual_length(self):
        with self.assertRaises(InvalidOrderError) as ctx:
            coerce_order_payload({"user_id": "u" * 300})
        self.assertIn("255", str(ctx.exception))
        self.assertIn("300", str(ctx.exception))

    def test_limit_is_measured_after_stripping(self):
        padded = "  " + "u" * MAX_USER_ID_LENGTH + "  "
        self.assertEqual(len(coerce_order_payload({"user_id": padded})[0]), MAX_USER_ID_LENGTH)

    def test_money_is_still_exact_for_a_maximum_length_user_id(self):
        amount = coerce_order_payload(
            {"user_id": "u" * MAX_USER_ID_LENGTH, "total_amount": "0.30"}
        )[2]
        self.assertIsInstance(amount, Decimal)
        self.assertEqual(str(amount), "0.30")


if __name__ == "__main__":
    unittest.main()
