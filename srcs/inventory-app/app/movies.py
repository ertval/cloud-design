from flask import Blueprint, request, jsonify
from app.extensions import db

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
    data = request.get_json(force=True, silent=True)
    if not data or "title" not in data or not str(data["title"]).strip():
        return jsonify({"error": "Field 'title' is required"}), 400

    movie = Movie(
        title=str(data["title"]).strip(),
        description=str(data.get("description", "")).strip() if data.get("description") is not None else ""
    )
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
    if not data:
        return jsonify({"error": "Invalid or missing JSON payload"}), 400

    if "title" in data:
        if not str(data["title"]).strip():
            return jsonify({"error": "Field 'title' cannot be empty"}), 400
        movie.title = str(data["title"]).strip()

    if "description" in data:
        movie.description = str(data.get("description", "")).strip()

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
    deleted_count = db.session.query(Movie).delete()
    db.session.commit()
    return jsonify({"message": f"All {deleted_count} movies deleted"}), 200

