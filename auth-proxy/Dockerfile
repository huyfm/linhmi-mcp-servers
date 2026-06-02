# GitHub-OAuth gateway for the read-only Atlassian MCP server.
# Thin, auth-only sidecar (see app.py). Built locally and pushed to public
# ghcr.io (scripts/deploy-azure.sh); runs alongside the unchanged mcp-atlassian
# container in the same Container App.
FROM python:3.12-slim

# Don't buffer stdout/stderr so Container Apps log streaming is live.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as a non-root user (matches the read-only/hardened posture of the deployment).
RUN useradd --create-home --uid 10001 appuser
USER appuser

# The proxy's external port (Container Apps ingress targetPort must match).
EXPOSE 8000

CMD ["python", "app.py"]
