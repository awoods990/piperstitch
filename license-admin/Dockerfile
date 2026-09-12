# License Admin as a container (Railway builds this automatically when the
# service's root directory is license-admin/). Plain uvicorn; TLS is the
# platform's job. The SQLite database lives on a mounted volume -- set
# DATABASE_PATH=/data/license_admin.db and mount a volume at /data.
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ app/
COPY scripts/ scripts/
RUN useradd --create-home --user-group licenseadmin && mkdir -p /data && chown licenseadmin:licenseadmin /data
USER licenseadmin
EXPOSE 8000
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
