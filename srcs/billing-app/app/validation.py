"""Dependency-free validation helpers for incoming billing orders.

Kept free of Flask, SQLAlchemy and pika imports so it can be unit-tested on the
host (`make test-py`) and reused by the consumer without pulling the whole
service in. The consumer callback must reject a malformed payload rather than
crash the worker, because an unacknowledged crash would block the queue.

Fully Python: strict parsing only. A value like "12abc" does not coerce to 12,
and non-string values are never stringified.
"""

import math
import re
from decimal import Decimal, InvalidOperation

# `orders.user_id` is VARCHAR(255) (srcs/billing-database/init.sql, matching
# String(255) in app/orders.py). A longer id cannot be stored: PostgreSQL raises
# StringDataRightTruncation on every attempt.
#
# It has to be rejected HERE, as a payload error, rather than left to the
# database. A permanently unpersistable message must NOT be requeued: with
# prefetch_count=1 an over-long user_id is redelivered, fails five times, is
# nacked and redelivered again - forever - which blocks the head of the queue
# and every legitimate order behind it. Rejecting it as an InvalidOrderError
# routes it into the existing poison-payload path (acknowledge and discard),
# which is the correct treatment for a message that can never succeed. A
# genuine database outage is still nacked with requeue=True and retried.
MAX_USER_ID_LENGTH = 255


class InvalidOrderError(ValueError):
    """Raised when a queue payload cannot be coerced into a valid order.

    Permanent failure (poison pill): the consumer acknowledges and discards
    the message instead of requeueing it. Any other exception is transient
    (database/infra) and the message is nacked back onto the queue for
    redelivery.
    """


# `orders.user_id` is an INTEGER (int4) column, but the AMQP payload carries a
# string ("20"), so the value is coerced before the insert. That keeps literal
# SQL such as `SELECT * FROM orders WHERE user_id=20;` working (comparing a
# text column to an integer is not a valid operator).
INT32_MIN = -2147483648
INT32_MAX = 2147483647
# `fullmatch`, not `match` against a `^...$` pattern: `$` also matches just
# before a trailing newline, so `match` would accept "12\n"; `fullmatch`
# pins the whole string and the newline form is rejected before stripping.
# Canonical decimal form only: optional leading `-`, then `0` or a non-zero
# digit followed by digits. Rejects `007`, `+5`, `1_2`, `1.5`, `12abc`.
# Surrounding whitespace is stripped before matching, so `" 12 "` is accepted.
_INTEGER_LITERAL = re.compile(r"-?(0|[1-9][0-9]*)")
# Plain decimal for money: no exponent, no underscores, digits required on
# both sides of a dot when present. Rejects `1e3`, `5.`, `1_2`, `NaN`.
# Mirrors the gateway edge check in srcs/api-gateway-app/app/proxy.py.
_DECIMAL_LITERAL = re.compile(r"[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)")


def parse_user_id(value):
    """Coerce to a 32-bit int, or return None when that is impossible.

    Strict: the whole (stripped) string must be an integer literal -- "12abc"
    and "5.9" are rejected, not truncated. None (rather than an exception)
    lets the caller raise a single InvalidOrderError naming every bad field
    instead of failing later as a database error.
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        parsed = value
    elif isinstance(value, float):
        if not math.isfinite(value) or not value.is_integer():
            return None
        parsed = int(value)
    elif isinstance(value, str):
        trimmed = value.strip()
        if not _INTEGER_LITERAL.fullmatch(trimmed):
            return None
        try:
            parsed = int(trimmed)
        except ValueError:
            return None
    else:
        return None
    if parsed < INT32_MIN or parsed > INT32_MAX:
        return None
    return parsed


def _coerce_int(value):
    """Strict whole-number coercion; None when the value is not usable."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        parsed = value
    elif isinstance(value, float):
        if not math.isfinite(value) or not value.is_integer():
            return None
        parsed = int(value)
    elif isinstance(value, str):
        trimmed = value.strip()
        if not _INTEGER_LITERAL.fullmatch(trimmed):
            return None
        try:
            parsed = int(trimmed)
        except ValueError:
            return None
    else:
        return None
    if parsed < 0 or parsed > INT32_MAX:
        return None
    return parsed


def _coerce_decimal(value):
    """Strict money coercion, returned as a Decimal for NUMERIC(12,2).

    Rejects booleans, nulls, containers, NaN/Infinity and anything Decimal
    cannot parse exactly. Finite floats travel through `str` (Python's
    shortest round-trip rendering, e.g. 0.1 -> "0.1") so no binary-float
    literal ever reaches the Decimal.
    """
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, Decimal):
        number = value
    elif isinstance(value, int):
        number = Decimal(value)
    elif isinstance(value, float):
        if not math.isfinite(value):
            return None
        number = Decimal(str(value))
    elif isinstance(value, str):
        trimmed = value.strip()
        if trimmed == "":
            return None
        if _DECIMAL_LITERAL.fullmatch(trimmed) is None:
            return None
        try:
            number = Decimal(trimmed)
        except InvalidOperation:
            return None
    else:
        return None
    if not number.is_finite():
        return None
    if number < 0:
        return None
    return number


def coerce_order_payload(payload):
    """Validate and coerce a decoded JSON payload into order field values.

    Returns (user_id: int, number_of_items: int, total_amount: Decimal).

    Every field is required: a missing or unusable field raises
    InvalidOrderError (poison pill -- ack and discard), never a transient
    retry, because requeueing a malformed payload can never succeed.

    Raises InvalidOrderError for anything that is not a usable order.
    """
    if not isinstance(payload, dict):
        raise InvalidOrderError("Payload must be a JSON object")

    # Bound the RAW payload field before coercing it. `orders.user_id` is an
    # INTEGER, so there is no VARCHAR to overflow -- but an unbounded field is
    # still a denial-of-service surface: the 900 KB user_id that once wedged the
    # live queue must be rejected as a payload error, not parsed. Measuring the
    # string we were handed (after strip) is what makes that bound meaningful.
    raw_user_id = payload.get("user_id")
    if isinstance(raw_user_id, str):
        if len(raw_user_id.strip()) > MAX_USER_ID_LENGTH:
            raise InvalidOrderError(
                f"user_id must be at most {MAX_USER_ID_LENGTH} characters "
                f"(received {len(raw_user_id.strip())})"
            )

    user_id = parse_user_id(payload.get("user_id"))
    number_of_items = _coerce_int(payload.get("number_of_items"))
    total_amount = _coerce_decimal(payload.get("total_amount"))

    if user_id is None or number_of_items is None or total_amount is None:
        raise InvalidOrderError(
            "Invalid order fields: user_id={!r}, number_of_items={!r}, "
            "total_amount={!r}".format(
                payload.get("user_id"),
                payload.get("number_of_items"),
                payload.get("total_amount"),
            )
        )
    if not user_id:
        raise InvalidOrderError("user_id cannot be empty")

    return user_id, number_of_items, total_amount
