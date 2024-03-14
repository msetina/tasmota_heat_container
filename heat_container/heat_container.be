#-
 - 
 -#
 import json
 import persist
 import mqtt
 import string 
 import heater_actuator
 
 #-A command supporting setup of heat container driver. It takes a JSON defining sensor array in heat_sensors list, 
 actuator list and material properties of the medium. It adds 2 virtual relays for each actuator.
 -#
 def heat_container_setup(cmd, idx, payload, payload_json)
    var hc_set
    var hc_set_topic
    var no_restart
    var resp = map()
    var preset_relays = {'All off':false}    
    # parse payload
    if payload_json != nil 
        no_restart = payload_json.find('no_restart')
        hc_set = payload_json.find('hc_set')
        hc_set_topic = payload_json.find('hc_set_topic')   
        if hc_set  
            var active_cnt = 0
            if hc_set.contains('actuators')
                var actuator_cnt = size(hc_set['actuators'])
                for act: hc_set['actuators']
                    if act.contains('name')
                        var nm = act['name']
                        act['backoff_name'] = 'Backoff ' + nm
                        act['run_name'] = 'Run ' + nm                        
                        preset_relays[act['run_name']] = false
                        preset_relays[act['backoff_name']] = false  
                        if act.contains('active') && act['active']   
                            active_cnt += 1                   
                        end
                        if active_cnt > 1
                            act['active'] = false
                        end
                        if actuator_cnt == 1 && active_cnt == 0
                            act['active'] = true
                        end 
                    end
                    actuator_cnt -= 1
                end
            end
            if active_cnt == 0
                resp['error'] = 'No active actuators'
            end
            if active_cnt > 1
                resp['error'] = 'More than one active actuators. Leaving on first found'
            end
            if hc_set.contains('relays')
                for r: hc_set['relays']
                    if r.contains('name')
                        if preset_relays.contains(r['name'])
                            preset_relays[r['name']] = true
                        end
                    end
                end
            else
                hc_set['relays'] = list()            
            end
            for p: preset_relays.keys()
                if !preset_relays[p]
                    hc_set['relays'].push({'name':p})
                end
            end
        end
    else
        resp['error'] = 'Malformed JSON or no setup parameter'         
        tasmota.resp_cmnd(resp)
        return   
    end    
    var sensor_def = nil
    if hc_set
        persist.hc_set = hc_set
        resp['hc_set'] = hc_set
        if hc_set.contains('heat_sensors')
            sensor_def = hc_set['heat_sensors']
        end
    end
    if hc_set_topic
        persist.hc_set_topic = hc_set_topic
        resp['hc_set_topic'] = hc_set_topic
    end    
    resp['free_sensors'] = list()
    var sensor_json = tasmota.read_sensors()
    try
        var sensors_o = json.load(sensor_json)
        resp['sensor_count'] = 0
        var input_temp_id = nil
        if hc_set.contains('input_temp_id')
            input_temp_id = hc_set['input_temp_id']
        end
        if sensors_o      
            for k: sensors_o.keys()
                if size(k)>6 && k[0..6] == 'DS18B20'
                    var temp = sensors_o[k]
                    var ident = temp['Id']
                    var found = false
                    resp['sensor_count'] += 1
                    if sensor_def
                        for sd: sensor_def
                            if sd.contains('id') && sd['id'] == ident
                                sd['check'] = true
                                found = true
                                break
                            end
                        end
                    end
                    #check if as input temp
                    if !found && input_temp_id == ident
                        found = true
                    end
                    #check if in definition
                    if !found
                        var el = {'id':ident,'temp':temp['Temperature']}
                        resp['free_sensors'].push(el)
                    end
                end
            end         
        end
    except .. as ex,m        
        resp['error'] = m
        tasmota.resp_cmnd(resp)
        return
    end
  
    # save to _persist.json
    persist.save() 
    #return data as they were saved to persist.
    tasmota.resp_cmnd(resp)
    # report the command as successful    
    if !no_restart
        tasmota.cmd('Restart 1')
    end
end

var heat_container = module('heat_container')

#-HeatContainer is a class supporting driving heat actuators by providing them with data read from DS18B20 sensor array 
attached to a container. Array is defined as sensor Ids and levels from bottom of container
-#
class HeatContainer        
    var temps
    var data
    var actuators
    var relay_idents    
    var overtemp

    var error
  
    def init()     
        self.data = map()
        self.temps=map()
        self.overtemp = false
        self.relay_idents = map()           
        self.actuators = map()   
        self.error = list()     
        self.subscribe_mqtt()        
        self.prep_virt_relays()
        self.prep_actuators()
    end

    def prep_virt_relays()
        if persist.has('hc_set') && persist.hc_set.contains('relays')
            for rel: persist.hc_set['relays']
                var ident    
                if rel.contains('ident')
                    ident = rel['ident']
                    if ident+1 > tasmota.global.devices_present
                        tasmota.global.devices_present = ident +1
                    end
                else
                    ident = tasmota.global.devices_present
                    rel['ident'] = ident
                    tasmota.global.devices_present += 1
                end  
                if rel.contains('last_val') && ident
                    var lv = rel['last_val']                                                    
                    tasmota.set_power(ident,lv)
                end
                if rel.contains('name')
                    var nm = rel['name']
                    self.relay_idents[nm] = ident                                        
                    var cmnd = string.format('FriendlyName%s %s',ident+1,rel['name'])
                    tasmota.cmd(cmnd)
                    var cmnd2 = string.format('WebButton%s %s',ident+1,rel['name'])
                    tasmota.cmd(cmnd2)
                end
            end
        end
    end  

    def prep_actuators()
        if persist.has('hc_set') && persist.hc_set.contains('actuators')            
            var active_cnt = 0
            var actuator_cnt = size(persist.hc_set['actuators'])
            for act: persist.hc_set['actuators']                
                if act.contains('name')
                    var nm = act['name']
                    var run_id
                    var backoff_id
                    var alloff_id
                    if act.contains('run_name')
                        var run_nm = act['run_name']
                        if self.relay_idents.contains(run_nm)
                            run_id = self.relay_idents[run_nm]
                        end
                    end
                    if act.contains('backoff_name')
                        var backoff_nm = act['backoff_name']
                        if self.relay_idents.contains(backoff_nm)
                            backoff_id = self.relay_idents[backoff_nm]
                        end
                    end
                    if self.relay_idents.contains('All off')
                        alloff_id = self.relay_idents['All off']
                    end                    
                    if act.contains('active') && act['active']   
                        active_cnt += 1                   
                    end
                    if active_cnt > 1
                        act['active'] = false
                    end
                    if actuator_cnt == 1 && active_cnt == 0
                        act['active'] = true
                    end 
                    self.actuators[nm] = heater_actuator.actuator(act,backoff_id,run_id,alloff_id)                                    
                    actuator_cnt -= 1
                end
            end
        end
    end

    def set_active_actuator(actuator_name)
        if persist.has('hc_set') && persist.hc_set.contains('actuators')            
            for act: persist.hc_set['actuators']
                if act.contains('name')
                    var nm = act['name']
                    if self.actuators.contains(nm)
                        if nm == actuator_name
                            act['active'] = true
                            self.actuators[nm].set_active(true)
                        else
                            act['active'] = false
                            self.actuators[nm].set_active(false)
                            self.actuators[nm].turn_off()
                        end                                                
                    else
                        self.error.push('Actuator not initialized')
                    end
                end
            end
        end
    end


    #- returns a list of temps in order of height on container
    -#
    def read_temps()
        var ret = true
        var sensor_json = tasmota.read_sensors()
        try
            var sensors_o = json.load(sensor_json)            
            if sensors_o       
                for k: sensors_o.keys()
                    if size(k)>6 && k[0..6] == 'DS18B20'
                        var temp = sensors_o[k]
                        self.temps[temp['Id']] = temp['Temperature']
                    elif k == 'Time'
                        self.temps[k] = sensors_o[k]
                    end
                end
            else
                self.error.push('Read temps error: Sensor data could not be parsed')
            end
        except .. as ex,m
            ret = false
            self.error.push('Read temps error:' + m)
        end
        return ret
    end
  
    #- returns energy values for each section-#
    def calc_energy()
        if !persist.has('hc_set') return end
        var in_temp = 0
        if persist.hc_set.contains('input_temp_id') && self.temps.contains(persist.hc_set['input_temp_id'])
            in_temp = self.temps[persist.hc_set['input_temp_id']]
        end
        if self.temps.contains('Time')
            self.data['Time'] = self.temps['Time']
        end
        var target_temp = 20
        if persist.hc_set.contains('target_temp')
            target_temp = persist.hc_set['target_temp']
        end
        var output_temp = 20
        if persist.hc_set.contains('output_temp')
            output_temp = persist.hc_set['output_temp']
        end
        var max_temp = 70
        if persist.hc_set.contains('max_temp')
            max_temp = persist.hc_set['max_temp']
        end

        var factor = 0.000001
        if persist.hc_set.contains('area') && persist.hc_set.contains('cp') && persist.hc_set.contains('ro')
            factor = persist.hc_set['area'] * persist.hc_set['cp'] * persist.hc_set['ro']
        end
        var full_h = 0
        var full_in_en = 0
        var full_stor_en = 0
        var full_cell_en = 0
        var prev_level = 0
        var prev_ident = nil
        self.overtemp = false
        #heat_sensors needs to be a list because map is not sorted
        #heat_sensors item contains id and level        
        if persist.hc_set.contains('heat_sensors')
            for h_def: persist.hc_set['heat_sensors']
                var h
                var lvl
                var ident
                if h_def.contains('id') 
                    ident = h_def['id']            
                end
                if h_def.contains('level') 
                    lvl = h_def['level']   
                    h = lvl - prev_level                      
                end            
                full_h += h
                if self.temps.contains(ident)
                    if !self.data.contains(ident) self.data[ident]=map() end
                    var curr_temp = self.temps[ident]
                    self.data[ident]['Height'] = h
                    self.data[ident]['Level'] = lvl
                    self.data[ident]['Temperature'] = curr_temp
                    if !self.overtemp
                        self.overtemp = max_temp < curr_temp ? true : false
                    end
                    var in_en = factor*h*(curr_temp - in_temp)
                    self.data[ident]['Energy to inlet'] = in_en
                    full_in_en += in_en
                    var stor_en = factor*h*(target_temp - curr_temp)
                    self.data[ident]['Energy to target'] = stor_en
                    full_stor_en += stor_en
                    var t_en = factor*h*(target_temp - in_temp)
                    self.data[ident]['Target energy'] = t_en 
                    self.data[ident]['Ratio'] = t_en!=0 ? in_en/t_en :0                    
                    if prev_ident && self.temps.contains(prev_ident)
                        var cell_en = factor*h*(curr_temp - self.temps[prev_ident])
                        self.data[ident]['Energy flow in cell'] = cell_en
                        full_cell_en += cell_en
                    end
                end
                prev_level = lvl
                prev_ident = ident
            end        
            if !self.data.contains('Container') self.data['Container'] = map() end
            var target_en_from_inlet = factor * full_h * (target_temp - in_temp)
            var f_output_en_from_inlet = factor * (output_temp - in_temp)
            var output_en_from_inlet = full_h * f_output_en_from_inlet            
            self.data['Container']['Target energy'] = target_en_from_inlet
            self.data['Container']['Energy for output'] = output_en_from_inlet
            self.data['Container']['Energy flow in cell'] = full_cell_en
            self.data['Container']['Energy to target'] = full_stor_en
            self.data['Container']['Energy to inlet'] = full_in_en
            self.data['Container']['Height'] = full_h
            self.data['Container']['Ratio'] = target_en_from_inlet!=0 ? full_in_en/target_en_from_inlet :0
            self.data['Container']['Target temp'] = target_temp
            self.data['Container']['Output temp'] = output_temp
            self.data['Container']['Inlet temp'] = in_temp
        end
    end

    def set_outputs()                      
        if persist.has('hc_set')
            for k :self.actuators.keys()
                var act = self.actuators[k]
                act.control_actuator(self.overtemp,self.data)                
            end
        end
    end

    def set_power_handler(cmd, idx)
        var new_state = tasmota.get_power()
        if persist.has('hc_set') && persist.hc_set.contains('relays')
            for rel: persist.hc_set['relays'] 
                var nm 
                if rel.contains('name')
                    nm = rel['name']   
                end                 
                var ident = rel['ident']                
                if ident <= size(new_state)
                    var st = new_state[ident]    
                    var lv = nil
                    if rel.contains('last_val')
                        lv = rel['last_val']
                    end
                    if lv != st
                        rel['last_val'] = st                                                                                                     
                    end
                end           
            end
        end
    end  

    def subscribe_mqtt() 
        if !persist.has('hc_set_topic') return nil end       
        if !persist.hc_set_topic return nil end  #- exit if not initialized -#
        #TODO: Add function in subscribe to get just sobscribed topic
        mqtt.subscribe(persist.hc_set_topic)        
    end
  
    #- trigger a read every second -#
    def every_second()
        if !persist.has('hc_set') return nil end  #- exit if not initialized -#  
        #if self.error 
        #    self.error = nil
        #end
        if self.read_temps()
            self.calc_energy()
            self.set_outputs()
        end
    end
  
    #- display sensor value in the web UI -#
    def web_sensor()
        if !self.data return nil end  #- exit if not initialized -#        
        var msg=''
        for k: self.data.keys()
            if k == 'Time' continue end
            msg += '{t}'
            var val_map = self.data[k]
            for kk: val_map.keys()
                var val = val_map[kk]
                msg += string.format('{s}%s %s{m}%.3f{e}',k,kk,val)
            end            
        end  
        for err:self.error     
            msg += string.format('{s}%s{e}',err)
        end
        tasmota.web_send_decimal(msg)
    end    
    #- add sensor value to teleperiod -#
    def json_append()
        if !self.data return nil end  #- exit if not initialized -#   
        var msg = ''            
        var cnt = 0
        for k: self.data.keys()
            if k == 'Time' continue end
            var sens = map()
            sens['Energy'] = map()
            sens['Temperature'] = map()
            if k != 'Container'
                sens['Id'] = k
            end
            for sk: self.data[k].keys()                              
                if sk == 'Target energy'
                    sens['Energy']['Total'] = self.data[k][sk]/1000
                elif sk =='Energy for output'
                    sens['Energy']['ForOutput'] = self.data[k][sk]/1000
                elif sk =='Energy flow in cell'
                    sens['Energy']['FlowInCell'] = self.data[k][sk]/1000
                elif sk =='Energy to target'
                    sens['Energy']['ToTarget'] = self.data[k][sk]/1000
                elif sk =='Energy to inlet'                
                    sens['Energy']['ToInlet'] = self.data[k][sk]/1000
                elif sk =='Temperature'                
                    sens['Temperature']['Now'] = self.data[k][sk]
                elif sk =='Target temp'                
                    sens['Temperature']['Target'] = self.data[k][sk]
                elif sk =='Output temp'                
                    sens['Temperature']['Output'] = self.data[k][sk]
                elif sk =='Inlet temp'                
                    sens['Temperature']['Inlet'] = self.data[k][sk]
                elif sk =='Ratio'                
                    sens['Percentage'] = self.data[k][sk]*100
                else
                    sens[sk] = self.data[k][sk]
                end                
            end
            if k == 'Container'    
                msg += string.format(',"HeatContainer":%s', json.dump(sens))
            else
                cnt += 1
                msg += string.format(',"HeatCell%s":%s', cnt,json.dump(sens))
            end
        end                  
        tasmota.response_append(msg)
    end

    def mqtt_data(topic, idx, data, databytes)
        var ret = false
        if !persist.has('hc_set_topic') return false end       
        if !persist.hc_set_topic return false end
        if topic == persist.hc_set_topic
            var target_temp
            var output_temp
            var input_temp_id
            var active_actuator
            var max_temp
            try
                var payload_json = json.load(data)
                if payload_json != nil 
                    target_temp = payload_json.find('target_temp')
                    output_temp = payload_json.find('output_temp')
                    max_temp = payload_json.find('max_temp')
                    active_actuator = payload_json.find('active_actuator')
                end
                if persist.has('hc_set')
                    if target_temp
                        persist.hc_set['target_temp'] = target_temp
                    end
                    if output_temp
                        persist.hc_set['output_temp'] = output_temp
                    end    
                    if max_temp
                        persist.hc_set['max_temp'] = max_temp
                    end   
                    if active_actuator
                        self.set_active_actuator(active_actuator)
                    end          
                    # save to _persist.json
                    persist.save()
                    ret = true
                end
            except .. as e,m
                ret = false
                self.error.push('MQTT error:' + m)
            end
        end
        return ret
    end
  
end

heat_container.driver = HeatContainer
heat_container.setup_command = heat_container_setup
heat_container.setup_command_name = 'HeatContainerSetup'

return heat_container