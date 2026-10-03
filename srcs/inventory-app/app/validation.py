"""Validation helpers for the inventory movie catalogue.

Kept free of Flask and SQLAlchemy imports so the rules can be unit-tested on the
host (`make test-py`) without a database or an application context.
"""


def validate_movie_payload(data, require_title: bool = True):
    """Return (title, description) from a decoded JSON body.

    Raises ValueError with a human-readable reason when the payload cannot be
    stored. `require_title` is True for creation, where a title is mandatory.
    """
    if not isinstance(data, dict) or not data:
        raise ValueError("Request body must be a JSON object")

    title = str(data.get("title", "")).strip() if data.get("title") is not None else ""
    if not title and require_title:
        raise ValueError("Field 'title' is required and cannot be empty")
    if "title" in data and not title:
        raise ValueError("Field 'title' cannot be empty")

    description = data.get("description")
    description = str(description).strip() if description is not None else ""

    return title, description