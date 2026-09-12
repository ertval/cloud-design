import os
import logging
from logging.handlers import RotatingFileHandler
from flask import Flask, jsonify, render_template_string, send_from_directory
from app.proxy import proxy_bp

def setup_logging():
    log_format = "%(asctime)s [%(levelname)s] [api-gateway-app] %(message)s"
    formatter = logging.Formatter(log_format)

    root_logger = logging.getLogger()
    root_logger.setLevel(logging.INFO)

    # Avoid adding duplicate handlers if reinitialized
    if not root_logger.handlers:
        # Stream Handler (stdout)
        stream_handler = logging.StreamHandler()
        stream_handler.setFormatter(formatter)
        root_logger.addHandler(stream_handler)

        # File Handler (persistent named volume at /usr/src/logs/gateway.log)
        log_dir = "/usr/src/logs"
        try:
            os.makedirs(log_dir, exist_ok=True)
            log_file = os.path.join(log_dir, "gateway.log")
            file_handler = RotatingFileHandler(
                log_file,
                maxBytes=5 * 1024 * 1024,  # 5MB
                backupCount=3,
                encoding="utf-8"
            )
            file_handler.setFormatter(formatter)
            root_logger.addHandler(file_handler)
        except Exception as e:
            root_logger.warning(f"Could not initialize file logger at {log_dir}: {e}")

SWAGGER_UI_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Play with Containers - API Gateway</title>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css" />
  <style>body { margin: 0; background: #fafafa; }</style>
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    window.onload = () => {
      window.ui = SwaggerUIBundle({
        url: '/openapi.yaml',
        dom_id: '#swagger-ui',
        deepLinking: true,
        presets: [
          SwaggerUIBundle.presets.apis,
          SwaggerUIBundle.SwaggerUIStandalonePreset
        ],
        layout: "BaseLayout"
      });
    };
  </script>
</body>
</html>
"""

def create_app():
    setup_logging()
    app = Flask(__name__)

    app.register_blueprint(proxy_bp)

    @app.route("/health", methods=["GET"])
    def health():
        return jsonify({"status": "healthy"}), 200

    @app.route("/api/docs", methods=["GET"])
    @app.route("/docs", methods=["GET"])
    def swagger_ui():
        return render_template_string(SWAGGER_UI_HTML)

    @app.route("/openapi.yaml", methods=["GET"])
    def openapi_spec():
        base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        # Check inside container or app root
        spec_path = os.path.join(base_dir, "openapi.yaml")
        if os.path.exists(spec_path):
            return send_from_directory(base_dir, "openapi.yaml", mimetype="text/yaml")
        return jsonify({"error": "OpenAPI specification not found"}), 404

    return app

