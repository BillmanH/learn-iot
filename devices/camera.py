# %%
import time
import uuid
import os
from datetime import datetime

from azure.iot.device import IoTHubDeviceClient
from azure.storage.blob import BlobClient
import cv2

# %%


class device:
    def __init__(self, connection):
        self.guid = str(uuid.uuid4())
        self.client = IoTHubDeviceClient.create_from_connection_string(
            connection)
        self.vid = cv2.VideoCapture(0)
        # maximum number of frames between saving images
        self.frame_cap = 1000
        # maximum number of images to save before recycling
        self.image_cap = 10
        # for iteration, should be set to 0
        self.frame_no = 0
        self.image_no = 0
        self.images_path = os.path.join('assets','images')


    def wait_for_message(self):
        message = self.client.receive_message()
        return message

    def sleep(self, n):
        time.sleep(n)
        return None

    def activate_monitor(self):
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
            self.frame_no += 1
            if self.frame_no==self.frame_cap:
                self.frame_no = 0
                print(f"{self.frame_cap}th frame reached")
                image_name = self.save_files(frame)
                self.post_data(image_name)
                result = self.upload_to_blob(image_name)
                print(result)
        # After the loop release the cap object
        self.vid.release()
        # Destroy all the windows
        cv2.destroyAllWindows()

    def save_files(self,frame):
        image_name = f'frame_{self.image_no}.jpg'
        cv2.imwrite(os.path.join(self.images_path,image_name), frame)
        self.image_no+=1
        if self.image_no>self.image_cap:
            self.image_no=1
        return image_name

    def post_data(self,image_name):
        datetime_1 = str(datetime.now())
        MSG_TXT = {"camera": self.guid,
                    "time":datetime_1,
                    "frame":self.frame_cap,
                    "image_name":image_name}
        # issue with the measage api can't handle single quotes. 
        self.client.send_message(str(MSG_TXT).replace('\'','"'))
        print(str(MSG_TXT))


    def upload_to_blob(self,image_name):
        try:
            blob_info = self.client.get_storage_info_for_blob(image_name)
            sas_url = f"https://{blob_info['hostName']}/{blob_info['containerName']}/{blob_info['blobName']}{blob_info['sasToken']}"
            with BlobClient.from_blob_url(sas_url) as blob_client:
                with open(os.path.join(self.images_path,image_name), "rb") as f:
                    result = blob_client.upload_blob(f, overwrite=True)
                    blob_client.close()
                    return result
        except Exception as e:
            print("unable to upload : ")
            self.client.disconnect()
            self.client.connect()
            return e



# %%
