# %%
import time
import uuid

import numpy as np


from azure.iot.device import IoTHubDeviceClient, Message
from azure.iot.hub import IoTHubRegistryManager


# %%


class device:
    def __init__(self, connection):
        self.guid = str(uuid.uuid4())
        self.client = IoTHubDeviceClient.create_from_connection_string(
            connection)
        self.temperature = 65

    def wait_for_message(self):
        message = self.client.receive_message()
        return message

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
# create a new fake device with a new connection string.
# d = thermostat.device(params['thermostat1'])


# # %%
# # Simulate the activity of that device
for i in range(20):
    d.monitor_temp(.5)
    print(f"temperature has changed to: {d.temperature}")
    d.post_data()
    d.sleep(4)
