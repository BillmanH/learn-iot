# Thermostat Simulator App. 
Simple, easy to build.

## building locally
Navigate to the path that contains the `Dockerfile`.

to build the app, run:
```
docker build . -t mythermostat:latest
```

Once it is built, you can test the app locally:
```
docker run -it mythermostat:latest
```


## Pushing to the Azure IoT workspace
