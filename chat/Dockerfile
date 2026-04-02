FROM python:3.12-slim
RUN pip install --no-cache-dir anthropic fastapi uvicorn mcp httpx-sse
WORKDIR /app
COPY server.py .
COPY system_prompt.txt .
COPY static/ static/
EXPOSE 3000
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "3000"]
