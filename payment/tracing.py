"""OpenTelemetry tracing for the payment service (Capstone 2, Step 4).

Replaces the Instana tracer the original image used. Everything is set up in
code here, and where traces go is read from the standard OTel environment
variables, which the Helm chart sets:

    OTEL_SERVICE_NAME=payment
    OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.tracing.svc.cluster.local:4318

With OTEL_SDK_DISABLED=true (the default when running outside Kubernetes,
see the Dockerfile) nothing is set up and payment runs exactly as before.

What ends up in a trace for one POST /pay/<id>:

    POST /pay/<id>                (Flask: the incoming request)
      GET  user:8080/check/<id>   (requests: is the user known?)
      GET  <payment gateway>      (requests: the "bank")
      orders publish              (pika: the order sent to RabbitMQ; the trace
                                   context goes along in the message headers)
      POST user:8080/order/<id>   (requests: order history)
      DELETE cart:8080/cart/<id>  (requests: empty the cart)
"""
import logging
import os

from flask.logging import default_handler
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor
from opentelemetry.instrumentation.pika import PikaInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

# every log line gets the trace it belongs to; Grafana turns the trace_id
# into a link to Jaeger (observability/logging/grafana-loki-datasource.yaml)
LOG_FORMAT = ('[%(asctime)s] %(levelname)s in %(module)s: '
              'trace_id=%(otelTraceID)s span_id=%(otelSpanID)s %(message)s')


def setup(app):
    """Start tracing for this Flask app. Call once, right after Flask(...)."""
    if os.getenv('OTEL_SDK_DISABLED', 'false').lower() == 'true':
        _log_trace_ids()
        app.logger.info('tracing disabled (OTEL_SDK_DISABLED=true)')
        return

    # service.name etc. come from OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES
    provider = TracerProvider(resource=Resource.create())
    # endpoint comes from OTEL_EXPORTER_OTLP_ENDPOINT
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

    # health checks and Prometheus scrapes would be most of the traces and
    # tell nothing, so they are not traced
    FlaskInstrumentor().instrument_app(app, excluded_urls='health,metrics')
    RequestsInstrumentor().instrument()
    PikaInstrumentor().instrument()
    _log_trace_ids()

    app.logger.info('tracing to %s as %s',
                    os.getenv('OTEL_EXPORTER_OTLP_ENDPOINT', 'http://localhost:4318'),
                    os.getenv('OTEL_SERVICE_NAME', 'unknown_service'))


def _log_trace_ids():
    """Put trace_id/span_id into payment's log lines.

    inject_trace_context adds otelTraceID / otelSpanID to every log record
    ("0" when there is no trace). The log export handler is turned off: logs
    still go to stdout and Fluent Bit, as before.
    """
    LoggingInstrumentor().instrument(inject_trace_context=True,
                                     enable_log_auto_instrumentation=False)
    # Flask's own log handler (what app.logger writes through)
    default_handler.setFormatter(logging.Formatter(LOG_FORMAT))
