import string

var heater_actuator = module('heater_actuator')

class HeaterActuator   
    var name 
    var relays
    var alloff_id
    var backoff_id
    var run_id    
    var control_id
    var control_value
    var control_max_value
    var control_min_value
    var max_on_time
    var min_off_time
    var active
    var off_milis
    var on_milis
    var prev_state


    def init(settings,backoff_id,run_id,alloff_id) 
        if settings.contains('name')   
            self.name = settings['name']
        else
            self.name = string.format('HeatActuator')
        end
        if settings.contains('relays')     
            self.relays = settings['relays']
            for ident: self.relays
                var cmnd = string.format('FriendlyName%s %s',ident+1,self.name)
                tasmota.cmd(cmnd)
                var cmnd2 = string.format('WebButton%s %s',ident+1,self.name)
                tasmota.cmd(cmnd2)
            end
        end
        if settings.contains('control_id')     
            self.control_id = settings['control_id']
        end
        if settings.contains('control_value')     
            self.control_value = settings['control_value']
        end
        if settings.contains('control_max_value')     
            self.control_max_value = settings['control_max_value']
        end
        if settings.contains('control_min_value')     
            self.control_min_value = settings['control_min_value']
        end
        if settings.contains('max_on_time')     
            self.max_on_time = settings['max_on_time']
        end
        if settings.contains('min_off_time')     
            self.min_off_time = settings['min_off_time']
            self.off_milis = -1000 * self.min_off_time
        else
            self.off_milis = 0
        end
        if settings.contains('active')     
            self.active = settings['active']            
        else
            self.active = false
        end
        self.alloff_id = alloff_id
        self.backoff_id = backoff_id
        self.run_id = run_id        
    end

    def set_active(active)
        self.active = active
    end

    def turn_off()
        var outputs = tasmota.get_power()  
        for id: self.relays
            if size(outputs)>=id && outputs[id]
                tasmota.set_power(id,false)
            end
        end        
        self.off_milis = tasmota.millis()  
        self.on_milis = nil      
    end

    def turn_on()                     
        for id: self.relays
            tasmota.set_power(id,true)
        end        
        self.on_milis = tasmota.millis()  
        self.off_milis = nil
    end

    def control_actuator(overtemp,data)
        var new_state = self.calc_new_state(overtemp,data)
        if self.prev_state != new_state
            if new_state
                self.turn_on()
            else
                self.turn_off()
            end
            self.prev_state = new_state
        end
    end

    def check_can_turn_on()
        if self.off_milis && self.min_off_time
            return ((tasmota.millis() - self.off_milis) > self.min_off_time*1000)
        else
            return true
        end
    end

    def check_needs_turn_off()
        if self.on_milis && self.max_on_time
            return ((tasmota.millis() - self.on_milis) > self.max_on_time*1000)
        else
            return false
        end
    end

    def calc_new_state(overtemp,data)        
        var outputs = tasmota.get_power()  
        if !self.active
            return false            
        end        
        if overtemp            
            return false
        end      
        if self.check_needs_turn_off()                            
            return false
        end  
        if self.alloff_id && (size(outputs)>=self.alloff_id) && outputs[self.alloff_id]
            return false
        end
        if self.backoff_id && (size(outputs)>=self.backoff_id) && outputs[self.backoff_id]
            return false
        end        
        if self.control_id && data && data.contains(self.control_id)
            var ct_id = data[self.control_id]
            if self.control_value && ct_id && ct_id.contains(self.control_value)
                var cv = ct_id[self.control_value]
                #utilize epsilon around control value to fix 
                #var delta_to_min = cv - self.control_min_value
                if cv
                    if self.run_id && (size(outputs)>=self.run_id) && outputs[self.run_id] && (cv < self.control_max_value) && self.check_can_turn_on()
                        return true
                    end
                    if cv < self.control_min_value
                        if self.check_can_turn_on()                            
                            return true
                        end
                    elif cv >= self.control_max_value
                        if self.run_id
                            tasmota.set_power(self.run_id,false)
                        end
                        return false
                    end
                end
            end
        else
            return false
        end
        return self.prev_state
    end

end


heater_actuator.actuator = HeaterActuator
return heater_actuator