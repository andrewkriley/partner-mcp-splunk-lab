FROM python:3.12-alpine
RUN pip install --no-cache-dir docker requests
WORKDIR /app
COPY server.py .
EXPOSE 8081
CMD ["python", "server.py"]
