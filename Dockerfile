FROM python:3.12-slim
WORKDIR /app
COPY bridge.py worker_example.py ./
# bridge bawaan hanya listen 127.0.0.1; di container butuh 0.0.0.0
RUN sed -i 's/addrs = \["127.0.0.1"\]/addrs = ["0.0.0.0"]/' bridge.py
ENV BRIDGE_QUEUE=/data/queue
EXPOSE 8765
CMD ["python", "bridge.py", "serve"]
