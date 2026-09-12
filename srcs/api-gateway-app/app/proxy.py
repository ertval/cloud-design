import os
import json
import logging
import requests
from flask import Blueprint, request, Response, jsonify
from app.queue_sender import RabbitMQSender

logger = logging.getLogger(__name__)
proxy_bp = Blueprint("proxy", __name__)
sender = RabbitMQSender()

INVENTORY_HOST = os.getenv("INVENTORY_APP_HOST", "inventory-app")
INVENTORY_PORT = os.getenv("INVENTORY_APP_PORT", "8080")

HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-length"
}

@proxy_bp.route("/api/movies", methods=["GET", "POST", "PUT", "DELETE"], strict_slashes=False)
@proxy_bp.route("/api/movies/<path:subpath>", methods=["GET", "POST", "PUT", "DELETE"], strict_slashes=False)
def proxy_movies(subpath=""):
    target_url = f"http://{INVENTORY_HOST}:{INVENTORY_PORT}/api/movies"
    if subpath:
        target_url = f"{target_url}/{subpath}"

    headers = {k: v for k, v in request.headers if k.lower() not in HOP_BY_HOP_HEADERS}

    try:
        resp = requests.request(
            method=request.method,
            url=target_url,
            headers=headers,
            params=request.args,
            data=request.get_data(),
            cookies=request.cookies,
            allow_redirects=False,
            timeout=10
        )

        response_headers = [
            (k, v) for k, v in resp.headers.items() if k.lower() not in HOP_BY_HOP_HEADERS
        ]

        logger.info(f"Proxied {request.method} {request.path} -> {target_url} [Status: {resp.status_code}]")
        return Response(resp.content, status=resp.status_code, headers=response_headers)

    except requests.exceptions.RequestException as e:
        logger.error(f"Error forwarding request to inventory service at {target_url}: {e}")
        return jsonify({"error": f"Inventory service unavailable: {str(e)}"}), 502


@proxy_bp.route("/api/billing", methods=["POST"], strict_slashes=False)
@proxy_bp.route("/api/billing/", methods=["POST"], strict_slashes=False)
def create_billing_order():
    data = request.get_json(force=True, silent=True)
    if not data or not isinstance(data, dict):
        return jsonify({"error": "Valid JSON body is required"}), 400

    raw_body = request.get_data(as_text=True)
    if not raw_body or not raw_body.strip():
        raw_body = json.dumps(data)

    try:
        sender.publish_message(raw_body)
        logger.info(f"Billing message enqueued: {raw_body}")
        return jsonify({"message": f"{raw_body} sent"}), 200
    except Exception as e:
        logger.error(f"Failed to queue billing message: {e}")
        return jsonify({"error": f"Failed to submit order to queue: {str(e)}"}), 500

