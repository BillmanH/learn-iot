import time
import uuid
import os
import numpy as np


from azure.iot.device import IoTHubDeviceClient



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
        # `bias` - will cause the temperature to slowly raise or decline over time. 
        # A bias of 0 will cause the teperature to randomly flux
        # bias = 1 will cause temperature to raise continuously 
        # bias = -1 will cause temperature to decline continuously
        dieroll = np.random.normal() + bias
        if dieroll <= .5:
            self.temperature -= 1
        else:
            self.temperature += 1

    def post_data(self):
        MSG_TXT = f'{{"temperature": {self.temperature}}}'
        self.client.send_message(MSG_TXT)
        print("Message successfully sent")


# Make a devices
d = device(os.getenv('IOT_CONNECTION_STR','unable to find env var: IOT_CONNECTION_STR'))

# Simulate the activity of that device
while True:
    d.monitor_temp(.9)
    print(f"temperature has changed to: {d1.temperature}")
    d.post_data()
    d.sleep(2)
