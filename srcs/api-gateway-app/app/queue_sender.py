import os
import time
import logging
import pika

logger = logging.getLogger(__name__)

class RabbitMQSender:
    def __init__(self):
        self.host = os.getenv("RABBITMQ_HOST", "rabbit-queue")
        self.port = int(os.getenv("RABBITMQ_PORT", "5672"))
        self.user = os.getenv("RABBITMQ_USER", "rabbit_user")
        self.password = os.getenv("RABBITMQ_PASSWORD", "rabbit_password")
        self.queue = os.getenv("RABBITMQ_QUEUE", "billing_queue")

    def _get_connection(self):
        credentials = pika.PlainCredentials(self.user, self.password)
        parameters = pika.ConnectionParameters(
            host=self.host,
            port=self.port,
            credentials=credentials,
            connection_attempts=3,
            retry_delay=1,
            socket_timeout=5
        )
        return pika.BlockingConnection(parameters)

    def publish_message(self, message: str, max_retries: int = 5) -> bool:
        """Publishes a durable persistent message to the RabbitMQ queue with retries."""
        last_exception = None
        for attempt in range(1, max_retries + 1):
            try:
                connection = self._get_connection()
                channel = connection.channel()
                channel.queue_declare(queue=self.queue, durable=True)
                channel.basic_publish(
                    exchange="",
                    routing_key=self.queue,
                    body=message.encode("utf-8"),
                    properties=pika.BasicProperties(
                        delivery_mode=pika.DeliveryMode.Persistent,
                        content_type="application/json"
                    )
                )
                connection.close()
                logger.info(f"Published message to queue '{self.queue}' on attempt {attempt}: {message}")
                return True
            except Exception as e:
                last_exception = e
                logger.warning(f"RabbitMQ publish attempt {attempt}/{max_retries} failed: {e}")
                time.sleep(1)

        logger.error(f"Failed to publish message after {max_retries} attempts: {last_exception}")
        raise RuntimeError(f"Could not publish message to RabbitMQ: {last_exception}")

