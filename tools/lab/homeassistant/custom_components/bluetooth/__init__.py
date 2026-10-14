"""Stands in for Home Assistant's Bluetooth integration in the House Control lab.

Run as a plain process on macOS, Home Assistant is killed the moment it touches
Bluetooth (it has no Bluetooth permission), and the lab has no Bluetooth devices anyway.
"""


async def async_setup(hass, config):
    return True
