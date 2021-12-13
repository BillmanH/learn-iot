# Flask App. 
Simple, easy to build.

## building locally
Navigate to the path that contains the `Dockerfile`.

to build the app, run:
```
docker build . -t myflaskapp:latest
```

Once it is built, you can test the app locally:
```
docker run -p 8000:8000 myflaskapp:latest
```
