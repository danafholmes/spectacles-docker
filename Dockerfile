FROM python:3.10

# Allow statements and log messages to immediately appear in the Cloud Run logs
ENV PYTHONUNBUFFERED True

COPY requirements.txt ./
COPY requirements-composer.txt ./
COPY requirements-test.txt ./

RUN pip install --no-cache-dir -r requirements.txt
RUN pip install --no-cache-dir -r requirements-test.txt
RUN pip install --no-cache-dir -r requirements-composer.txt

CMD ["sh", "-c", "spectacles sql --base-url https://4mile.looker.com --client-id $SPECTACLES_ID --client-secret $SPECTACLES_SECRET --verbose --project dana_test --branch $_HEAD_BRANCH --incremental"]
