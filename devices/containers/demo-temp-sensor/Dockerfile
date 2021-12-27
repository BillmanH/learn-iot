FROM python:3.7-slim-buster

WORKDIR /app

COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY . .

EXPOSE  8081
CMD [ "python3", "./app.py"]