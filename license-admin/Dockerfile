# License Admin as a container (Railway builds this automatically when the
# service's root directory is license-admin/). Plain uvicorn; TLS is the
# platform's job.
#
# The SQLite database defaults to /data/license_admin.db so it lands on a
# volume mounted at /data. Runs as root on purpose: Railway mounts volumes
# root-owned, and a non-root process can't create the database there --
# the first deploy crashed exactly that way. The container has nothing
# else in it, so this costs nothing.
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 DATABASE_PATH=/data/license_admin.db
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ app/
COPY scripts/ scripts/
RUN mkdir -p /data
EXPOSE 8000
CMD ["sh", "-c", "mkdir -p \"$(dirname \"$DATABASE_PATH\")\" && uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
