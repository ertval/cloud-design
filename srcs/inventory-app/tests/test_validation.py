"""Unit tests for the inventory movie validation rules.

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


class ValidateMoviePayloadTest(unittest.TestCase):
    def test_title_is_trimmed(self):
        self.assertEqual(validate_movie_payload({"title": "Dune"}), ("Dune", ""))

    def test_title_and_description_are_trimmed(self):
        payload = {"title": "  Dune  ", "description": "  sand and spice  "}
        self.assertEqual(validate_movie_payload(payload), ("Dune", "sand and spice"))

    def test_missing_description_defaults_to_empty_string(self):
        self.assertEqual(validate_movie_payload({"title": "Dune"})[1], "")

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
        for bad in ([], None, "Dune", 42, ()):
            with self.assertRaises(ValueError):
                validate_movie_payload(bad)

    def test_rejects_an_empty_body(self):
        with self.assertRaises(ValueError):
            validate_movie_payload({})

    def test_rejects_a_missing_or_blank_title(self):
        for bad in ({"title": ""}, {"title": "   "}, {"description": "no title"}):
            with self.assertRaises(ValueError):
                validate_movie_payload(bad)

    def test_error_messages_name_the_offending_field(self):
        with self.assertRaisesRegex(ValueError, "title"):
            validate_movie_payload({"title": ""})


if __name__ == "__main__":
    unittest.main()
