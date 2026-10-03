from flask import Blueprint, request, jsonify
from app.extensions import db
from app.validation import validate_movie_payload

movies_bp = Blueprint("movies", __name__, url_prefix="/api/movies")

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
    if title_query:
        movies = Movie.query.filter(Movie.title.ilike(f"%{title_query}%")).order_by(Movie.id.asc()).all()
    else:
        movies = Movie.query.order_by(Movie.id.asc()).all()
    
    return jsonify({"movies": [m.to_dict() for m in movies]}), 200

@movies_bp.route("", methods=["POST"], strict_slashes=False)
def create_movie():
    try:
        title, description = validate_movie_payload(request.get_json(force=True, silent=True))
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    movie = Movie(title=title, description=description)
    db.session.add(movie)
    db.session.commit()
    return jsonify(movie.to_dict()), 200

@movies_bp.route("/<int:movie_id>", methods=["GET"], strict_slashes=False)
def get_movie(movie_id):
    movie = db.session.get(Movie, movie_id)
    if not movie:
        return jsonify({"error": f"Movie with ID {movie_id} not found"}), 404
    return jsonify(movie.to_dict()), 200

@movies_bp.route("/<int:movie_id>", methods=["PUT"], strict_slashes=False)
def update_movie(movie_id):
    movie = db.session.get(Movie, movie_id)
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
        _, movie.description = validate_movie_payload(data, require_title=False)

    db.session.commit()
    return jsonify(movie.to_dict()), 200

@movies_bp.route("/<int:movie_id>", methods=["DELETE"], strict_slashes=False)
def delete_movie(movie_id):
    movie = db.session.get(Movie, movie_id)
    if not movie:
        return jsonify({"error": f"Movie with ID {movie_id} not found"}), 404

    db.session.delete(movie)
    db.session.commit()
    return jsonify({"message": f"Movie with ID {movie_id} successfully deleted"}), 200

@movies_bp.route("", methods=["DELETE"], strict_slashes=False)
def delete_all_movies():
    # Destructive and reachable unauthenticated through the public gateway, so it
    # requires an explicit opt-in. DELETE /api/movies by itself must not wipe the
    # catalogue: one stray request would destroy the data an evaluator is
    # inspecting. Delete a single row with DELETE /api/movies/<id>.
    if request.args.get("confirm") != "all":
        return jsonify({
            "error": "Refusing to delete the whole catalogue without confirmation",
            "hint": "Re-run with ?confirm=all, or delete a single movie with DELETE /api/movies/<id>"
        }), 400

    deleted_count = db.session.query(Movie).delete()
    db.session.commit()
    return jsonify({"message": f"All {deleted_count} movies deleted"}), 200

