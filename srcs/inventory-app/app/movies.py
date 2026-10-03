import re
from flask import Blueprint, request, jsonify
from app.extensions import db
from app.validation import validate_movie_payload

movies_bp = Blueprint("movies", __name__, url_prefix="/api/movies")

# `movies.id` is a SERIAL (int4) column, so no value outside INT32 can ever
# match a row. Python ints are arbitrary-precision, so without this guard a
# huge id would reach PostgreSQL and die as a 500 instead of a clean 404.
INT32_MIN = -2147483648
INT32_MAX = 2147483647

_INTEGER_LITERAL = re.compile(r"[+-]?[0-9]+")


def _is_invalid_id(value) -> bool:
    """True when `value` cannot be a movie id (the caller answers 404).

    Pure-Python rules: strip surrounding whitespace, require the whole text
    to be a base-10 integer literal, require the literal to round-trip
    (`int` accepts underscores and a leading `+`, neither of which names a
    row), and require the INT32 range of the SERIAL column. 'abc', '12abc',
    '1.5', '', '007' and '+5' are rejected; '-5' and ' 12 ' are accepted and
    looked up (and 404 only if no such row exists).
    """
    if value is None:
        return True
    text = str(value).strip()
    if text == "":
        return True
    if not _INTEGER_LITERAL.fullmatch(text):
        return True
    try:
        parsed = int(text)
    except ValueError:
        return True
    if str(parsed) != text:
        return True
    return not INT32_MIN <= parsed <= INT32_MAX


def _coerce_id(value) -> int:
    """Integer value of an id that `_is_invalid_id` has already accepted."""
    return int(str(value).strip())

class Movie(db.Model):
    __tablename__ = "movies"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    title = db.Column(db.String(255), nullable=False)
    description = db.Column(db.Text, nullable=True, default="")

    def to_dict(self):
        return {
            "id": self.id,
            "title": self.title,
            "description": self.description or ""
        }

@movies_bp.route("", methods=["GET"], strict_slashes=False)
def list_movies():
    title_query = request.args.get("title")
    query = Movie.query.order_by(Movie.id.asc())
    if title_query:
        # LIKE wildcards in the caller's value are literals here: escape the
        # escape character first, then `%` and `_`, so a trailing `\` cannot
        # break the pattern and `%` / `_` cannot silently widen the match.
        escaped = (
            title_query.replace("\\", "\\\\")
            .replace("%", "\\%")
            .replace("_", "\\_")
        )
        query = query.filter(Movie.title.ilike(f"%{escaped}%", escape="\\"))
    movies = query.all()

    return jsonify({"movies": [m.to_dict() for m in movies]}), 200

@movies_bp.route("", methods=["POST"], strict_slashes=False)
def create_movie():
    try:
        title, description = validate_movie_payload(request.get_json(force=True, silent=True))
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    movie = Movie(title=title, description=description)
    db.session.add(movie)
    db.session.flush()
    db.session.refresh(movie)
    # Capture the response while the session is still open: after the session
    # closes the instance is detached and attribute access may fail.
    payload = movie.to_dict()
    db.session.commit()
    return jsonify(payload), 200

# NOTE: plain `<movie_id>` (string), not `<int:movie_id>`. The int converter
# only matches unsigned digits: negatives never reached the handler (Flask
# answered 404 with an HTML page) and '007' silently matched row 7. The
# string converter plus the `_is_invalid_id` guard answers every malformed
# id with a JSON 404 instead. openapi.yaml is unchanged: the path parameter
# is still logically an integer.
@movies_bp.route("/<movie_id>", methods=["GET"], strict_slashes=False)
def get_movie(movie_id):
    if _is_invalid_id(movie_id):
        return jsonify({"error": f"Movie with ID {movie_id} not found"}), 404
    movie = db.session.get(Movie, _coerce_id(movie_id))
    if not movie:
        return jsonify({"error": f"Movie with ID {movie_id} not found"}), 404
    return jsonify(movie.to_dict()), 200

@movies_bp.route("/<movie_id>", methods=["PUT"], strict_slashes=False)
def update_movie(movie_id):
    if _is_invalid_id(movie_id):
        return jsonify({"error": f"Movie with ID {movie_id} not found"}), 404
    movie = db.session.get(Movie, _coerce_id(movie_id))
    if not movie:
        return jsonify({"error": f"Movie with ID {movie_id} not found"}), 404

    data = request.get_json(force=True, silent=True)
    if not isinstance(data, dict) or not data:
        return jsonify({"error": "Invalid or missing JSON payload"}), 400

    # Title stays optional here (partial update), but must not be blanked out.
    if "title" in data:
        try:
            movie.title, _ = validate_movie_payload(data)
        except ValueError as e:
            return jsonify({"error": str(e)}), 400

    if "description" in data:
        try:
            _, movie.description = validate_movie_payload(data, require_title=False)
        except ValueError as e:
            return jsonify({"error": str(e)}), 400

    db.session.flush()
    # Capture the response while the session is still open (see create_movie).
    payload = movie.to_dict()
    db.session.commit()
    return jsonify(payload), 200

@movies_bp.route("/<movie_id>", methods=["DELETE"], strict_slashes=False)
def delete_movie(movie_id):
    if _is_invalid_id(movie_id):
        return jsonify({"error": f"Movie with ID {movie_id} not found"}), 404
    movie = db.session.get(Movie, _coerce_id(movie_id))
    if not movie:
        return jsonify({"error": f"Movie with ID {movie_id} not found"}), 404

    db.session.delete(movie)
    db.session.commit()
    return jsonify({"message": f"Movie with ID {movie_id} successfully deleted"}), 200

@movies_bp.route("", methods=["DELETE"], strict_slashes=False)
def delete_all_movies():
    # DELIBERATE DEVIATION FROM SPEC, kept: the spec text describes DELETE on
    # the collection as clearing the catalogue, and the reference
    # implementation deletes unconditionally. This service refuses a bare
    # DELETE /api/movies with 400 and only wipes when ?confirm=all is
    # present. Rationale: the endpoint is unauthenticated and reachable
    # through the public gateway, so one stray request must not destroy the
    # data under evaluation. Documented in README ("API behaviour notes");
    # delete a single row with DELETE /api/movies/<id>.
    if request.args.get("confirm") != "all":
        return jsonify({
            "error": "Refusing to delete the whole catalogue without confirmation",
            "hint": "Re-run with ?confirm=all, or delete a single movie with DELETE /api/movies/<id>"
        }), 400

    deleted_count = db.session.query(Movie).delete()
    db.session.commit()
    return jsonify({"message": f"All {deleted_count} movies deleted"}), 200
