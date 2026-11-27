// A Homebridge plugin with pretend devices, for testing House Control's Homebridge connection
// without hardware: lamps with every kind of control, a plug and a switch, an air conditioner
// (HomeKit "heater cooler"), a thermostat and a thermometer. Started by tools/lab/homebridge.sh.
//
// Every change an app makes is logged, and the thermometer drifts towards what the AC is set to,
// so both directions can be watched.
'use strict';

module.exports = (api) => {
  api.registerPlatform('homebridge-house-lab', 'HouseLab', HouseLab);
};

class HouseLab {
  constructor(log, config, api) {
    this.log = log;
    this.api = api;
  }

  accessories(callback) {
    const { Service, Characteristic, uuid } = this.api.hap;
    const log = this.log;
    const made = [];

    const accessory = (name, build) => {
      const info = new Service.AccessoryInformation()
        .setCharacteristic(Characteristic.Manufacturer, 'House Control Lab')
        .setCharacteristic(Characteristic.Model, name)
        .setCharacteristic(Characteristic.SerialNumber, uuid.generate(name).slice(0, 8));
      const services = build();
      made.push({ name, getServices: () => [info, ...services] });
      return services[0];
    };
    // Characteristics keep their own value; a setter only has to log it.
    const watch = (name, service, characteristic) => {
      service.getCharacteristic(characteristic).onSet((value) => log.info(`${name}: ${characteristic.name || 'value'} → ${JSON.stringify(value)}`));
    };

    const lamp = (name, { dim = false, white = false, colour = false } = {}) => accessory(name, () => {
      const s = new Service.Lightbulb(name);
      watch(name, s, Characteristic.On);
      if (dim) { s.getCharacteristic(Characteristic.Brightness).updateValue(70); watch(name, s, Characteristic.Brightness); }
      if (white) { s.getCharacteristic(Characteristic.ColorTemperature).updateValue(320); watch(name, s, Characteristic.ColorTemperature); }
      if (colour) {
        s.getCharacteristic(Characteristic.Hue).updateValue(30);
        s.getCharacteristic(Characteristic.Saturation).updateValue(60);
        watch(name, s, Characteristic.Hue);
        watch(name, s, Characteristic.Saturation);
      }
      return [s];
    });

    const onOff = (name, Type) => accessory(name, () => {
      const s = new Type(name);
      watch(name, s, Characteristic.On);
      if (Type === Service.Outlet) s.getCharacteristic(Characteristic.OutletInUse).updateValue(true);
      return [s];
    });

    const airConditioner = (name, roomTemp) => accessory(name, () => {
      const s = new Service.HeaterCooler(name);
      s.getCharacteristic(Characteristic.CurrentTemperature).updateValue(roomTemp);
      s.getCharacteristic(Characteristic.TargetHeaterCoolerState).updateValue(Characteristic.TargetHeaterCoolerState.COOL);
      s.getCharacteristic(Characteristic.CoolingThresholdTemperature).setProps({ minValue: 16, maxValue: 30, minStep: 1 }).updateValue(24);
      s.getCharacteristic(Characteristic.HeatingThresholdTemperature).setProps({ minValue: 16, maxValue: 30, minStep: 1 }).updateValue(22);
      s.getCharacteristic(Characteristic.RotationSpeed).setProps({ minValue: 0, maxValue: 100, minStep: 25 }).updateValue(50);
      s.getCharacteristic(Characteristic.SwingMode).updateValue(0);
      for (const c of [Characteristic.Active, Characteristic.TargetHeaterCoolerState, Characteristic.CoolingThresholdTemperature,
        Characteristic.HeatingThresholdTemperature, Characteristic.RotationSpeed, Characteristic.SwingMode]) watch(name, s, c);
      // The unit reports what it is doing from what it was asked to do.
      const C = Characteristic.CurrentHeaterCoolerState;
      const current = () => {
        const active = s.getCharacteristic(Characteristic.Active).value === 1;
        const target = s.getCharacteristic(Characteristic.TargetHeaterCoolerState).value;
        s.getCharacteristic(C).updateValue(!active ? C.INACTIVE : target === 1 ? C.HEATING : target === 2 ? C.COOLING : C.IDLE);
      };
      s.getCharacteristic(Characteristic.Active).on('change', current);
      s.getCharacteristic(Characteristic.TargetHeaterCoolerState).on('change', current);
      current();
      return [s];
    });

    const thermostat = (name) => accessory(name, () => {
      const s = new Service.Thermostat(name);
      s.getCharacteristic(Characteristic.CurrentTemperature).updateValue(21);
      s.getCharacteristic(Characteristic.TargetTemperature).setProps({ minValue: 10, maxValue: 30, minStep: 0.5 }).updateValue(21);
      s.getCharacteristic(Characteristic.TargetHeatingCoolingState).updateValue(Characteristic.TargetHeatingCoolingState.HEAT);
      for (const c of [Characteristic.TargetHeatingCoolingState, Characteristic.TargetTemperature]) watch(name, s, c);
      return [s];
    });

    const sensor = (name, value) => accessory(name, () => {
      const s = new Service.TemperatureSensor(name);
      s.getCharacteristic(Characteristic.CurrentTemperature).updateValue(value);
      return [s];
    });

    lamp('Lab Ceiling', { dim: true, white: true });
    lamp('Lab Floor Lamp', { dim: true });
    lamp('Lab Colour Strip', { dim: true, white: true, colour: true });
    onOff('Lab Plug', Service.Outlet);
    onOff('Lab Lamp Switch', Service.Switch);
    const ac = airConditioner('Lab AC', 26.5);
    thermostat('Lab Heating');
    const thermometer = sensor('Lab Thermometer', 26.5);

    // The room cools while the AC runs, and warms up again when it stops.
    setInterval(() => {
      const t = thermometer.getCharacteristic(Characteristic.CurrentTemperature);
      const on = ac.getCharacteristic(Characteristic.Active).value === 1;
      const goal = on ? ac.getCharacteristic(Characteristic.CoolingThresholdTemperature).value : 27;
      const next = Math.round((t.value + Math.sign(goal - t.value) * Math.min(0.2, Math.abs(goal - t.value))) * 10) / 10;
      if (next !== t.value) { t.updateValue(next); ac.getCharacteristic(Characteristic.CurrentTemperature).updateValue(next); }
    }, 5000).unref();

    callback(made);
  }
}
