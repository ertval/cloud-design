"""Dependency-free validation helpers for incoming billing orders.

Kept free of Flask, SQLAlchemy and pika imports so it can be unit-tested on the
host (`make test-py`) and reused by the consumer without pulling the whole
service in. The consumer callback must reject a malformed payload rather than
crash the worker, because an unacknowledged crash would block the queue.
"""


from decimal import Decimal, InvalidOperation


class InvalidOrderError(ValueError):
    """Raised when a queue payload cannot be coerced into a valid order."""


def coerce_order_payload(payload):
    """Validate and coerce a decoded JSON payload into order field values.

    The audit posts every numeric field as a JSON *string* (`"99"`, `"250"`), so
    the coercion is part of the contract rather than defensive coding.

    Raises InvalidOrderError for anything that is not a usable order.
    """
    if not isinstance(payload, dict):
        raise InvalidOrderError("Payload must be a JSON object")

    try:
        user_id = str(payload.get("user_id", "")).strip()
        number_of_items = int(payload.get("number_of_items", 0))
        raw_amount = payload.get("total_amount", "0.0")
        if raw_amount is None:
            raise ValueError("total_amount cannot be null")
        total_amount = Decimal(str(raw_amount))
    except (TypeError, ValueError, InvalidOperation) as exc:
        raise InvalidOrderError(f"Field coercion failed: {exc}") from exc

    if not user_id:
        raise InvalidOrderError("user_id cannot be empty")

    return user_id, number_of_items, total_amount