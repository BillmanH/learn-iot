# Azure IOT-HUB

Working out some evening and weekend code to see if I can get an azure IOT hub working. 

* `device_simulator.py` is just like the sensor example in the MSFT docs, but simplified and actually works. 

### What you need:
`key_thermostat1.yaml` should contain the key that you got from the azure portal. 

Looks like this:
```
connection_string: HostName={your hostname};DeviceId={id};SharedAccessKey={access key}
```