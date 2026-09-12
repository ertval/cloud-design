import os
import json
import time
import logging
import pika
from app.orders import Order

logger = logging.getLogger(__name__)

def start_consuming(db_session_factory, stop_event=None):
    rabbitmq_host = os.getenv("RABBITMQ_HOST", "rabbit-queue")
    rabbitmq_port = int(os.getenv("RABBITMQ_PORT", "5672"))
    rabbitmq_user = os.getenv("RABBITMQ_USER", "rabbit_user")
    rabbitmq_password = os.getenv("RABBITMQ_PASSWORD", "rabbit_password")
    queue_name = os.getenv("RABBITMQ_QUEUE", "billing_queue")

    credentials = pika.PlainCredentials(rabbitmq_user, rabbitmq_password)
    parameters = pika.ConnectionParameters(
        host=rabbitmq_host,
        port=rabbitmq_port,
        credentials=credentials,
        heartbeat=60,
        blocked_connection_timeout=300
    )

    logger.info(f"Billing consumer starting up. Target queue: {queue_name} on {rabbitmq_host}:{rabbitmq_port}")

    while stop_event is None or not stop_event.is_set():
        connection = None
        try:
            logger.info("Attempting connection to RabbitMQ broker...")
            connection = pika.BlockingConnection(parameters)
            channel = connection.channel()

            # Ensure the queue is durable
            channel.queue_declare(queue=queue_name, durable=True)
            channel.basic_qos(prefetch_count=1)

            logger.info(f"Connected to RabbitMQ. Waiting for billing messages on '{queue_name}'...")

            def callback(ch, method, properties, body):
                logger.info(f"Received raw message delivery #{method.delivery_tag}: {body.decode('utf-8', errors='replace')}")
                try:
                    payload = json.loads(body.decode("utf-8"))
                except Exception as json_err:
                    logger.error(f"Malformed non-JSON payload received: {json_err}. Acknowledging to avoid queue head-of-line blocking.")
                    ch.basic_ack(delivery_tag=method.delivery_tag)
                    return

                # Robust type coercion according to contract
                try:
                    if not isinstance(payload, dict):
                        raise ValueError("Payload must be a JSON object")
                    user_id = str(payload.get("user_id", "")).strip()
                    number_of_items = int(payload.get("number_of_items", 0))
                    total_amount = float(payload.get("total_amount", 0.0))

                    if not user_id:
                        raise ValueError("user_id cannot be empty")
                except Exception as parse_err:
                    logger.error(f"Invalid order fields in payload {payload}: {parse_err}. Acknowledging and discarding poison message.")
                    ch.basic_ack(delivery_tag=method.delivery_tag)
                    return

                # Persist order to billing database with bounded retries
                db_success = False
                for retry in range(5):
                    session = db_session_factory()
                    try:
                        order = Order(
                            user_id=user_id,
                            number_of_items=number_of_items,
                            total_amount=total_amount
                        )
                        session.add(order)
                        session.commit()
                        logger.info(f"Successfully processed and recorded order #{order.id} for user '{user_id}' (items={number_of_items}, total=${total_amount:.2f})")
                        db_success = True
                        break
                    except Exception as db_err:
                        session.rollback()
                        logger.warning(f"Database insertion retry {retry + 1}/5 failed: {db_err}")
                        time.sleep(1)
                    finally:
                        session.close()

                # Always acknowledge once handled (or if persistent DB failures exceeded limit, log and ack to maintain queue flow)
                ch.basic_ack(delivery_tag=method.delivery_tag)
                if not db_success:
                    logger.error(f"Failed to persist order after retries. Payload: {payload}")

            channel.basic_consume(queue=queue_name, on_message_callback=callback, auto_ack=False)
            channel.start_consuming()

        except (pika.exceptions.AMQPConnectionError, pika.exceptions.AMQPChannelError) as amqp_err:
            logger.warning(f"RabbitMQ connection lost/unavailable: {amqp_err}. Retrying in 3 seconds...")
            time.sleep(3)
        except Exception as e:
            logger.error(f"Unexpected error in consumer loop: {e}. Retrying in 3 seconds...")
            time.sleep(3)
        finally:
            if connection and connection.is_open:
                try:
                    connection.close()
                except Exception:
                    pass

