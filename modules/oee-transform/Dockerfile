# Build via ACR Tasks (no local Docker needed):
#   az acr build --registry <ACR_NAME> --image oee-transform:latest \
#                --file modules/oee-transform/Dockerfile modules/oee-transform
#
# Or with Build-OeeTransform.ps1 which reads ACR name from aio_config.json.

FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py transform.py ./

ENV MQTT_BROKER=aio-broker.azure-iot-operations.svc.cluster.local \
    MQTT_PORT=18883 \
    INPUT_TOPIC=factory/# \
    OUTPUT_PREFIX=factory/transformed \
    MQTT_AUTH_METHOD=K8S-SAT \
    SAT_TOKEN_PATH=/var/run/secrets/tokens/broker-sat \
    PYTHONUNBUFFERED=1

CMD ["python3", "app.py"]
