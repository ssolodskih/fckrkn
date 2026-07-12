# yacfsocks relay as a Yandex Serverless Container.
# Stdlib only - no pip install needed (requirements.txt is empty).
FROM python:3.14-slim

WORKDIR /app
COPY handler.py serve_local.py ./

# serve_local.py binds HOST:PORT; the container listens on all interfaces.
# TOKEN / EXCHANGE_WAIT / allowlist env come from the revision --environment.
ENV HOST=0.0.0.0 \
    PORT=8080
EXPOSE 8080

CMD ["python", "serve_local.py"]
