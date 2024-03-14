import heat_container

var hc = heat_container.driver()
tasmota.add_driver(hc)
tasmota.add_cmd(heat_container.setup_command_name, heat_container.setup_command)    