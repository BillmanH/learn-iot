# %%
import time
import uuid

import numpy as np
import yaml


from azure.iot.device import IoTHubDeviceClient, Message
from azure.iot.hub import IoTHubRegistryManager

params = yaml.safe_load(open('key_thermostat1.yaml'))
# %%


class device:
    def __init__(self):
        self.guid = str(uuid.uuid4())
        self.client = IoTHubDeviceClient.create_from_connection_string(
            params['connection_string'])
        self.temperature = 65

    def sleep(self, n):
        time.sleep(n)
        return None

    def monitor_temp(self, bias):
        dieroll = np.random.normal() + bias
        if dieroll <= .5:
            self.temperature -= 1
        else:
            self.temperature += 1

    def post_data(self):
        MSG_TXT = f'{{"temperature": {self.temperature}}}'
        self.client.send_message(MSG_TXT)
        print("Message successfully sent")


# %%
d = device()


# %%

for i in range(20):
    d.monitor_temp(.5)
    print(f"temperature has changed to: {d.temperature}")
    d.sleep(4)

# %%
