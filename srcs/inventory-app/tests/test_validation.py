"""Unit tests for the inventory movie validation rules.

FULLY STRICT Python: no implicit `str()` conversion. `title` must be a genuine
`str` and `description` must be a `str` or `None` — dicts, lists and numbers
are rejected instead of being stringified.

Dependency-free on purpose: `python3 -m unittest discover -s tests` runs on a
bare host with no Flask, no SQLAlchemy and no database, which is what
`make test-py` does. `app/validation.py` is kept import-light for exactly this
reason.
"""

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

validate_movie_payload = validation.validate_movie_payload
MAX_TITLE_LENGTH = validation.MAX_TITLE_LENGTH


class ValidateMoviePayloadTest(unittest.TestCase):
    def test_title_is_trimmed(self):
        self.assertEqual(validate_movie_payload({"title": "Dune"}), ("Dune", ""))

    def test_title_and_description_are_trimmed(self):
        payload = {"title": "  Dune  ", "description": "  sand and spice  "}
        self.assertEqual(validate_movie_payload(payload), ("Dune", "sand and spice"))

    def test_missing_description_defaults_to_empty_string(self):
        self.assertEqual(validate_movie_payload({"title": "Dune"})[1], "")

    def test_none_description_defaults_to_empty_string(self):
        self.assertEqual(validate_movie_payload({"title": "Dune", "description": None}), ("Dune", ""))

    def test_partial_update_may_omit_the_title(self):
        self.assertEqual(
            validate_movie_payload({"description": "sequel"}, require_title=False),
            ("", "sequel"),
        )

    def test_extra_fields_are_ignored(self):
        # `year` is accepted and dropped rather than rejected, so a client can
        # post a richer object without the API refusing the whole request.
        self.assertEqual(validate_movie_payload({"title": "Dune", "year": 2026}), ("Dune", ""))

    def test_rejects_payloads_that_are_not_a_json_object(self):
        for bad in ([], None, "Dune", 42, (), True, 3.14, ["title"]):
            with self.assertRaises(ValueError):
                validate_movie_payload(bad)

    def test_rejects_an_empty_body(self):
        with self.assertRaises(ValueError):
            validate_movie_payload({})

    def test_rejects_a_missing_or_blank_title(self):
        for bad in ({"title": ""}, {"title": "   "}, {"description": "no title"}):
            with self.assertRaises(ValueError):
                validate_movie_payload(bad)

    def test_rejects_non_string_title(self):
        # STRICT: no str() coercion. None/bool/numbers/dicts/lists are not titles.
        for bad_title in (None, True, False, 123, 3.14, {"t": "x"}, ["Dune"], ("Dune",)):
            with self.assertRaises(ValueError):
                validate_movie_payload({"title": bad_title})

    def test_rejects_non_string_description(self):
        # STRICT: no str() coercion to "[object Object]" / "1,2" style text.
        for bad_desc in (123, 3.14, True, False, {"text": "x"}, ["a", "b"], ("x",)):
            with self.assertRaises(ValueError):
                validate_movie_payload({"title": "Dune", "description": bad_desc})
            with self.assertRaises(ValueError):
                validate_movie_payload(
                    {"description": bad_desc}, require_title=False
                )

    def test_error_messages_name_the_offending_field(self):
        with self.assertRaisesRegex(ValueError, "title"):
            validate_movie_payload({"title": ""})
        with self.assertRaisesRegex(ValueError, "description"):
            validate_movie_payload({"title": "Dune", "description": {"a": 1}})


class TitleLengthBoundaryTest(unittest.TestCase):
    """The VARCHAR(255) boundary.

    A 256-character title used to pass validation and then die in PostgreSQL with
    StringDataRightTruncation, which the gateway relayed to the client as a raw
    Flask 500 page. These tests pin the exact edge that used to fall through.
    """

    def test_limit_matches_the_database_column_width(self):
        # srcs/inventory-database/init.sql: VARCHAR(255) plus a CHECK constraint
        # of the same bound. If one of the three drifts, this fails first.
        self.assertEqual(MAX_TITLE_LENGTH, 255)

    def test_accepts_a_title_of_exactly_the_maximum_length(self):
        title = "A" * MAX_TITLE_LENGTH
        self.assertEqual(validate_movie_payload({"title": title}), (title, ""))

    def test_rejects_a_title_one_character_over_the_maximum(self):
        # The exact input that produced the unhandled 500.
        with self.assertRaises(ValueError):
            validate_movie_payload({"title": "A" * (MAX_TITLE_LENGTH + 1)})

    def test_rejects_a_much_longer_title(self):
        with self.assertRaises(ValueError):
            validate_movie_payload({"title": "T" * 900_000})

    def test_length_message_names_the_field_the_limit_and_the_actual_length(self):
        with self.assertRaisesRegex(ValueError, r"'title'") as ctx:
            validate_movie_payload({"title": "A" * 300})
        self.assertIn("255", str(ctx.exception))
        self.assertIn("300", str(ctx.exception))

    def test_limit_is_measured_after_stripping(self):
        padded = "  " + "A" * MAX_TITLE_LENGTH + "  "
        self.assertEqual(len(validate_movie_payload({"title": padded})[0]), MAX_TITLE_LENGTH)

    def test_rejects_an_overlong_title_on_a_partial_update_too(self):
        # PUT takes the same validator, so the boundary must hold there as well;
        # otherwise the fix only covers POST.
        with self.assertRaises(ValueError):
            validate_movie_payload(
                {"description": "ok", "title": "A" * (MAX_TITLE_LENGTH + 1)},
                require_title=False,
            )

    def test_description_is_not_length_limited_because_the_column_is_text(self):
        # `description` is TEXT, not VARCHAR, so 900 KB must be accepted: this is
        # what makes a 900 KB request body legal rather than a 500.
        big = "D" * 900_000
        self.assertEqual(validate_movie_payload({"title": "Dune", "description": big})[1], big)


if __name__ == "__main__":
    unittest.main()
