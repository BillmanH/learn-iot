# %%
import yaml
# import scripts.thermostat as thermostat
import scripts.camera as camera
# import scripts.compressor as compressor

params = yaml.safe_load(open('iot_keys.yaml'))

# %%
# create a new fake device with a new connection string.
# d1 = thermostat.device(params['thermostat1'])
# d2 = thermostat.device(params['thermostat2'])
d3 = camera.device(params['camera1'])
d3.activate_monitor()

# %%
# Simulate the activity of that device
# for i in range(20):
#     d1.monitor_temp(.9)
#     # d2.monitor_temp(.8)
#     print(f"temperature has changed to: {d1.temperature}")
#     d1.post_data()
#     d1.sleep(2)
#     # d2.post_data()
#     # d2.sleep(2)

# %%
# note that this will just spin until new information is collected.

# message = d.wait_for_message()
# %%
