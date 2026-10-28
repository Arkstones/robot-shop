# payment, rebuilt for Capstone 2 Step 4 (OpenTelemetry instead of Instana).
# Built and pushed to ghcr.io/arkstones/rs-payment by
# .github/workflows/payment-image.yml.
#
# Changes from the original image:
# - python:3.9 (end of life) -> python:3.12-slim, and pinned requirements
# - uwsgi -> gunicorn: gunicorn installs without a C compiler, so the slim
#   image works. Like uwsgi's lazy-apps, each gunicorn worker loads the app
#   after it starts, which OpenTelemetry's background exporter thread needs.
# - runs as a non-root user
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    # off unless the deployment turns it on, so the image also runs on its own
    OTEL_SDK_DISABLED=true

WORKDIR /app

COPY requirements.txt /app/
RUN pip install -r requirements.txt

COPY *.py /app/

RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin payment
USER 10001

EXPOSE 8080

# 1 worker, 4 threads: the shop's /metrics counters live in one process, so
# Prometheus sees every sale. Access log on stdout ("GET /pay/... 500"),
# which Fluent Bit reads the level from.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "4", \
     "--access-logfile", "-", "--no-control-socket", "payment:app"]
