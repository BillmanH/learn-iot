# %%
import yaml
import scripts.thermostat as thermostat
# import scripts.compressor as compressor

params = yaml.safe_load(open('key_thermostat1.yaml'))

# %%
# create a new fake device with a new connection string.
d1 = thermostat.device(params['thermostat1'])
# d2 = thermostat.device(params['thermostat2'])

# %%
# Simulate the activity of that device
for i in range(20):
    d1.monitor_temp(.9)
    # d2.monitor_temp(.8)
    print(f"temperature has changed to: {d1.temperature}")
    d1.post_data()
    d1.sleep(2)
    # d2.post_data()
    # d2.sleep(2)

# %%
# note that this will just spin until new information is collected.

# message = d.wait_for_message()
# %%
