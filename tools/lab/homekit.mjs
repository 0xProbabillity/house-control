// A pretend HomeKit home for testing House Control's Apple Home support without any hardware:
// a bridge with dimmable, white-tunable and colour lamps, a plug, two air conditioners
// (HomeKit "heater coolers") and a temperature sensor. Add it in the Home app — or in the
// iOS Simulator — like a real accessory, using the setup code it prints.
//
//   cd tools/lab && npm install && npm run homekit
//
// Every change an app makes is printed, and the sensor's reading drifts, so you can watch both
// directions. State is kept in tools/lab/.homekit (delete it to unpair and start over).
import { Accessory, Bridge, Categories, Characteristic, HAPStorage, MDNSAdvertiser, Service, uuid } from 'hap-nodejs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
HAPStorage.setCustomStoragePath(path.join(here, '.homekit'));

const PIN = process.env.PIN || '031-45-154';
const PORT = Number(process.env.PORT || 51826);
const NAME = process.env.NAME || 'House Control Lab';

const bridge = new Bridge(NAME, uuid.generate(`house-control-lab:${NAME}`));
bridge.getService(Service.AccessoryInformation)
  .setCharacteristic(Characteristic.Manufacturer, 'House Control')
  .setCharacteristic(Characteristic.Model, 'Lab bridge')
  .setCharacteristic(Characteristic.SerialNumber, 'HC-LAB-1');

const log = (who, what, value) => console.log(`${new Date().toLocaleTimeString()}  ${who.padEnd(18)} ${what} → ${JSON.stringify(value)}`);

// Characteristics keep their own value; a setter just has to accept it.
function watch(name, service, characteristic) {
  service.getCharacteristic(characteristic).on('set', (value, done) => { log(name, characteristic.name || 'value', value); done(); });
}

function accessory(name, category) {
  const a = new Accessory(name, uuid.generate(`house-control-lab:${NAME}:${name}`));
  a.category = category;
  a.getService(Service.AccessoryInformation)
    .setCharacteristic(Characteristic.Manufacturer, 'House Control Lab')
    .setCharacteristic(Characteristic.Model, name)
    .setCharacteristic(Characteristic.SerialNumber, uuid.generate(name).slice(0, 8));
  bridge.addBridgedAccessory(a);
  return a;
}

function lamp(name, { dim = false, white = false, colour = false } = {}) {
  const a = accessory(name, Categories.LIGHTBULB);
  const s = a.addService(Service.Lightbulb, name);
  watch(name, s, Characteristic.On);
  if (dim) { s.getCharacteristic(Characteristic.Brightness).updateValue(70); watch(name, s, Characteristic.Brightness); }
  if (white) { s.getCharacteristic(Characteristic.ColorTemperature).updateValue(320); watch(name, s, Characteristic.ColorTemperature); }
  if (colour) {
    s.getCharacteristic(Characteristic.Hue).updateValue(30);
    s.getCharacteristic(Characteristic.Saturation).updateValue(60);
    watch(name, s, Characteristic.Hue);
    watch(name, s, Characteristic.Saturation);
  }
  return s;
}

function plug(name) {
  const a = accessory(name, Categories.OUTLET);
  const s = a.addService(Service.Outlet, name);
  watch(name, s, Characteristic.On);
  return s;
}

function airConditioner(name, roomTemp) {
  const a = accessory(name, Categories.AIR_CONDITIONER);
  const s = a.addService(Service.HeaterCooler, name);
  s.getCharacteristic(Characteristic.CurrentTemperature).updateValue(roomTemp);
  s.getCharacteristic(Characteristic.TargetHeaterCoolerState).updateValue(Characteristic.TargetHeaterCoolerState.COOL);
  s.getCharacteristic(Characteristic.CoolingThresholdTemperature).updateValue(24).setProps({ minValue: 16, maxValue: 30, minStep: 1 });
  s.getCharacteristic(Characteristic.HeatingThresholdTemperature).updateValue(22).setProps({ minValue: 16, maxValue: 30, minStep: 1 });
  s.getCharacteristic(Characteristic.RotationSpeed).setProps({ minValue: 0, maxValue: 100, minStep: 25 }).updateValue(50);
  s.getCharacteristic(Characteristic.SwingMode).updateValue(0);
  for (const c of [Characteristic.Active, Characteristic.TargetHeaterCoolerState, Characteristic.CoolingThresholdTemperature,
    Characteristic.HeatingThresholdTemperature, Characteristic.RotationSpeed, Characteristic.SwingMode]) watch(name, s, c);
  // The unit reports what it is doing from what it was asked to do.
  const current = () => {
    const active = s.getCharacteristic(Characteristic.Active).value === 1;
    const target = s.getCharacteristic(Characteristic.TargetHeaterCoolerState).value;
    const C = Characteristic.CurrentHeaterCoolerState;
    s.getCharacteristic(C).updateValue(!active ? C.INACTIVE : target === 1 ? C.HEATING : target === 2 ? C.COOLING : C.IDLE);
  };
  s.getCharacteristic(Characteristic.Active).on('change', current);
  s.getCharacteristic(Characteristic.TargetHeaterCoolerState).on('change', current);
  current();
  return s;
}

function sensor(name, value) {
  const a = accessory(name, Categories.SENSOR);
  const s = a.addService(Service.TemperatureSensor, name);
  s.getCharacteristic(Characteristic.CurrentTemperature).updateValue(value);
  return s;
}

lamp('Living Ceiling', { dim: true, white: true });
lamp('Floor Lamp', { dim: true });
lamp('TV Backlight', { dim: true, colour: true });
lamp('Kitchen Spots', { dim: true, white: true, colour: true });
plug('Bedside Plug');
const livingAC = airConditioner('Living AC', 26.5);
airConditioner('Bedroom AC', 25);
const thermometer = sensor('Living Thermometer', 26.5);

// The room cools while the living room AC runs, and warms again when it stops.
setInterval(() => {
  const t = thermometer.getCharacteristic(Characteristic.CurrentTemperature);
  const on = livingAC.getCharacteristic(Characteristic.Active).value === 1;
  const goal = on ? livingAC.getCharacteristic(Characteristic.CoolingThresholdTemperature).value : 27;
  const next = Math.round((t.value + Math.sign(goal - t.value) * Math.min(0.2, Math.abs(goal - t.value))) * 10) / 10;
  if (next !== t.value) { t.updateValue(next); livingAC.getCharacteristic(Characteristic.CurrentTemperature).updateValue(next); }
}, 5000);

bridge.publish({
  username: process.env.USERNAME || '0E:5C:A1:AB:00:01',
  pincode: PIN,
  port: PORT,
  category: Categories.BRIDGE,
  advertiser: MDNSAdvertiser.CIAO,
});

console.log(`\n${NAME} is on the network (port ${PORT}).`);
console.log(`Add it in the Home app: + → Add Accessory → More options… → ${NAME}, setup code ${PIN}`);
console.log(`Setup URI (for a QR code): ${bridge.setupURI()}\n`);
