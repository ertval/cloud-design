"""Validation helpers for the inventory movie catalogue.

Kept free of Flask and SQLAlchemy imports so the rules can be unit-tested on the
host (`make test-py`) without a database or an application context.
"""

# The catalogue's `title` column is `VARCHAR(255)` (see
# srcs/inventory-database/init.sql, which also enforces it with a CHECK
# constraint, and `String(255)` in srcs/inventory-app/app/movies.py). PostgreSQL
# rejects a longer value with StringDataRightTruncation, which used to surface as
# an unhandled 500 with a raw traceback page, so the boundary is enforced HERE
# first and answered with a 400 that names the field and the limit.
#
# `description` has no such limit: the column is `TEXT` (unbounded, ~1 GB) and
# the request body is already capped at 1 MiB by MAX_CONTENT_LENGTH, so an
# over-long description is storable rather than a truncation error.
MAX_TITLE_LENGTH = 255


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
    # Measured AFTER stripping, so the limit is on the value that is stored and
    # `len()` counts characters the way VARCHAR(n) does, not bytes.
    if len(title) > MAX_TITLE_LENGTH:
        raise ValueError(
            f"Field 'title' must be at most {MAX_TITLE_LENGTH} characters "
            f"(received {len(title)})"
        )

    description = data.get("description")
    description = str(description).strip() if description is not None else ""

    return title, description