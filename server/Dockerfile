FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Run as an unprivileged user. The app only ever writes inside /app/data,
# which is the bind-mounted SQLite directory. On Linux hosts that directory
# must be writable by uid 10001 (macOS file sharing does not enforce this).
RUN adduser --disabled-password --gecos "" --uid 10001 appuser \
    && mkdir -p /app/data \
    && chown -R appuser /app
USER appuser

ENV PYTHONUNBUFFERED=1

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["python3", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).status == 200 else 1)"]

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
