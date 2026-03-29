FROM python:3.13-slim AS base

WORKDIR /app

# Install system deps (none needed for slim, but leave hook for future)
RUN apt-get update && apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Install Python deps
COPY pyproject.toml ./
RUN pip install --no-cache-dir .

# Copy application code
COPY app/ ./app/

# Create a non-root user
RUN useradd --create-home appuser
USER appuser

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
