# %%
import time
import uuid
from datetime import datetime

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
        self.frame_cap = 100
        # print(self.client.get_storage_info_for_blob("camera-images"))


    def wait_for_message(self):
        message = self.client.receive_message()
        return message

    def sleep(self, n):
        time.sleep(n)
        return None

    def activate_monitor(self):
        frame_no = 0
        image_no = 0
        while(True):
            # self.client.connect()
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
            if frame_no==self.frame_cap:
                print(f"{frame_no}th frame reached")
                image_name = f'assets/images/frame_{image_no}.jpg'
                cv2.imwrite(image_name, frame)
                image_no+=1
                if image_no>10:
                    image_no=1
                self.post_data(image_name)
                # self.upload_to_blob(image_name)
                frame_no = 0
            # self.client.disconnect()
        # After the loop release the cap object
        self.vid.release()
        # Destroy all the windows
        cv2.destroyAllWindows()

    def save_files(self,frame_no,image_no):
        frame_no += 1
        if frame_no==self.frame_cap:
            print(f"{frame_no}th frame reached")
        image_name = f'assets/images/frame_{image_no}.jpg'
        cv2.imwrite(image_name, frame)
        image_no+=1
        if image_no>10:
            image_no=1
            self.post_data(image_name)
        # self.upload_to_blob(image_name)
        frame_no = 0

    def post_data(self,image_name):
        datetime_1 = str(datetime.now())
        MSG_TXT = {"camera": self.guid,
                    "time":datetime_1,
                    "frame":self.frame_cap,
                    "image_name":image_name}
        self.client.send_message(str(MSG_TXT).replace('\'','"'))
        print(str(MSG_TXT))


    def upload_to_blob(self,image_name):
        f = open(image_name, "rb").read()
        print("IoTHubClient is uploading blob to storage")
        self.client.upload_blob_async(image_name, f)




# %%
