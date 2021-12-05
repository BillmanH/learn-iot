# Setting up my local IoT Space using MQTT

My local MQTT device is an Intel Nuc, which I can access via SSH on the local network. `ssh billmanh@{local-ip}`. The `default.conf` I'm suing is pretty default, but allows all devices to communicatie with it. There are better tutorials on installing mosquitto so I'll leave that for them. 

## Testing connections
first subscribe to a topic:
```
mosquitto_sub -v -t 'test/topic'
```

Then go to another device and ping it to make sure that the server is open and listening:
```
mosquitto_pub -h {ip of your server (local-ip)} -t 'test/topic' -m 'helloWorld'
```

If you return to the Nuc (the server) and see `helloWorld` then you have a connection and are listening on the device. 

## Connecting it with Azure

