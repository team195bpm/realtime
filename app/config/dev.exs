import Config
# In dev, we use a local folder for mnesia so it doesn't crash
config :mnesia, dir: 'mnesia_dev_data'
