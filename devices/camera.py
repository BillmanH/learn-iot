# %%
import time
import uuid

import numpy as np


from azure.iot.device import IoTHubDeviceClient, Message
import cv2

# %%


class device:
    def __init__(self, connection):
        self.guid = str(uuid.uuid4())
        self.client = IoTHubDeviceClient.create_from_connection_string(
            connection)
        self.vid = cv2.VideoCapture(0)


    def wait_for_message(self):
        message = self.client.receive_message()
        return message

    def sleep(self, n):
        time.sleep(n)
        return None

    def activate_monitor(self):
        frame_no = 0
        while(True):
            # Capture the video frame
            # by frame
            ret, frame = self.vid.read()

            # Display the resulting frame
            cv2.imshow('frame', frame)

            # the 'q' button is set as the
            # quitting button you may use any
            # desired button of your choice
            if cv2.waitKey(1) & 0xFF == ord('q'):
                break
            frame_no += 1
            if frame_no==100:
                print(f"{frame_no}th frame reached")
                cv2.imwrite('frame1.jpg', frame)
                frame_no = 0
        # After the loop release the cap object
        self.vid.release()
        # Destroy all the windows
        cv2.destroyAllWindows()


    def post_data(self):
        MSG_TXT = f'{{"camera": {self.guid}}}'
        self.client.send_message(MSG_TXT)
        print("Message successfully sent")


    def post_data(self):
        MSG_TXT = f'{{"compression": {self.vibration}}}'
        self.client.send_message(MSG_TXT)
        print("Message successfully sent")





# %%
