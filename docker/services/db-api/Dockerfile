FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir "setuptools<70" && \
    pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8082

CMD ["python", "app.py"]
