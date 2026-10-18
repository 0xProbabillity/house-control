// Home Assistant's vocabulary at the boundary; the plan and clients use HouseCore terms.
const celsius = (value, attributes) =>
  attributes.temperature_unit === "°F" ? ((value - 32) * 5) / 9 : value;
const nativeTemperature = (value, attributes) =>
  attributes.temperature_unit === "°F" ? (value * 9) / 5 + 32 : value;
export const modeTable = (a) =>
  Object.fromEntries(
    Object.entries({
      cool: ["cool"],
      heat: ["heat"],
      dry: ["dry"],
      fan: ["fan_only"],
      auto: ["auto", "heat_cool"],
    }).flatMap(([k, v]) => {
      const n = v.find((x) => a.includes(x));
      return n ? [[k, n]] : [];
    }),
  );
export function fanPanel(name) {
  const n = name.toLowerCase();
  for (const [key, words] of Object.entries({
    turbo: [
      "turbo",
      "max",
      "strong",
      "highest",
      "powerful",
      "boost",
      "very high",
    ],
    high: ["high"],
    medium: ["med", "mid"],
    low: ["low", "quiet", "silent"],
    auto: ["auto"],
  }))
    if (words.some((w) => n.includes(w))) return key;
}
export const fanTable = (names) => {
  const out = {};
  for (const n of names) {
    const p = fanPanel(n);
    if (p && !out[p]) out[p] = n;
  }
  return out;
};
export function device(s) {
  const id = s.entity_id,
    a = s.attributes || {},
    domain = id.split(".")[0];
  const d = {
    service: "homeassistant",
    id,
    name: a.friendly_name || id,
    online: !["unavailable", "unknown"].includes(s.state),
    capabilities: [],
    detail: domain,
  };
  if (domain === "light") {
    d.kind = "light";
    const modes = a.supported_color_modes || [];
    d.capabilities = ["brightness", "temp", "color"].filter((c) =>
      c === "brightness"
        ? modes.some((m) => m !== "onoff")
        : c === "temp"
          ? modes.includes("color_temp")
          : modes.some((m) => ["hs", "xy", "rgb", "rgbw", "rgbww"].includes(m)),
    );
  } else if (domain === "switch") d.kind = "light";
  else if (domain === "climate") {
    d.kind = "ac";
    d.min = Math.max(
      a.min_temp === undefined ? 16 : celsius(a.min_temp, a),
      10,
    );
    d.max = Math.min(
      a.max_temp === undefined ? 30 : celsius(a.max_temp, a),
      32,
    );
  } else if (
    domain === "sensor" &&
    (a.device_class === "temperature" ||
      ["°C", "°F"].includes(a.unit_of_measurement))
  )
    d.kind = "sensor";
  else return null;
  return d;
}
export function reading(s) {
  const a = s.attributes || {},
    online = !["unavailable", "unknown"].includes(s.state),
    out = { online };
  if (!online) return out;
  if (/^(light|switch)\./.test(s.entity_id)) {
    out.light = { on: s.state === "on" };
    if (s.state === "on" && Number.isFinite(a.brightness))
      out.light.brightness = Math.max(0.05, Math.min(1, a.brightness / 255));
    if (a.color_mode === "color_temp" && Number.isFinite(a.color_temp_kelvin))
      Object.assign(out.light, { temp: a.color_temp_kelvin, color: null });
    else if (a.rgb_color?.length === 3)
      out.light.color =
        "#" +
        a.rgb_color
          .map((n) => Math.round(n).toString(16).padStart(2, "0"))
          .join("");
  } else if (s.entity_id.startsWith("climate.")) {
    const modes = modeTable(a.hvac_modes || []),
      fans = fanTable(a.fan_modes || []),
      presets = a.preset_modes || [];
    out.ac = { on: s.state !== "off" };
    const mode = Object.keys(modes).find((k) => modes[k] === s.state);
    if (mode) out.ac.mode = mode;
    if (Number.isFinite(a.temperature))
      out.ac.target = celsius(a.temperature, a);
    else if (
      Number.isFinite(a.target_temp_low) &&
      Number.isFinite(a.target_temp_high)
    )
      out.ac.target = celsius((a.target_temp_low + a.target_temp_high) / 2, a);
    if (Number.isFinite(a.current_temperature))
      out.ac.roomTemp = celsius(a.current_temperature, a);
    if (a.fan_mode && fanPanel(a.fan_mode)) out.ac.fan = fanPanel(a.fan_mode);
    if (a.swing_mode) out.ac.swing = a.swing_mode === "off" ? "off" : "swing";
    for (const p of ["sleep", "eco"])
      if (presets.includes(p)) out.ac[p] = a.preset_mode === p;
    out.features = {
      modes: Object.keys(modes),
      fans: Object.keys(fans),
      swing:
        (a.swing_modes || []).includes("off") &&
        (a.swing_modes || []).length > 1,
      sleep: presets.includes("sleep"),
      eco: presets.includes("eco"),
    };
  } else if (
    s.entity_id.startsWith("sensor.") &&
    Number.isFinite(Number(s.state))
  )
    out.temperature =
      a.unit_of_measurement === "°F"
        ? ((Number(s.state) - 32) * 5) / 9
        : Number(s.state);
  return out;
}
export function calls(s, patch, state = {}) {
  const d = device(s),
    a = s.attributes || {},
    domain = s.entity_id.split(".")[0],
    out = [];
  const add = (service, data = {}) =>
    out.push({ domain, service, data: { entity_id: s.entity_id, ...data } });
  const bad = (msg) => {
    throw new Error(msg);
  };
  if (!d || !d.online) bad("Device is unavailable");
  const allowed =
    d.kind === "light"
      ? ["on", ...d.capabilities.map((x) => (x === "temp" ? "temp" : x))]
      : ["on", "mode", "target", "fan", "swing", "sleep", "eco"];
  for (const [key, value] of Object.entries(patch)) {
    // The UI clears its previous RGB selection when switching to white temperature.
    if (domain === "light" && key === "color" && value === null) continue;
    if (!allowed.includes(key)) bad(`Unsupported control: ${key}`);
    if (["on", "sleep", "eco"].includes(key) && typeof value !== "boolean")
      bad(`Invalid ${key}`);
    if (
      ["brightness", "temp", "target"].includes(key) &&
      !Number.isFinite(value)
    )
      bad(`Invalid ${key}`);
  }
  if (domain === "light" || domain === "switch") {
    if (patch.on === false) add("turn_off");
    else {
      const data = {};
      if (patch.brightness !== undefined) {
        if (patch.brightness < 0.05 || patch.brightness > 1)
          bad("Invalid brightness");
        data.brightness_pct = Math.round(patch.brightness * 100);
      }
      if (patch.temp !== undefined) {
        if (patch.temp < 2200 || patch.temp > 6500) bad("Invalid temperature");
        data.color_temp_kelvin = Math.round(patch.temp);
      }
      if (patch.color !== undefined && patch.color !== null) {
        if (!/^#[\da-f]{6}$/i.test(patch.color)) bad("Invalid color");
        data.rgb_color = [1, 3, 5].map((i) =>
          parseInt(patch.color.slice(i, i + 2), 16),
        );
      }
      if (Object.keys(data).length || patch.on === true) add("turn_on", data);
    }
  } else if (domain === "climate") {
    const modes = modeTable(a.hvac_modes || []),
      fans = fanTable(a.fan_modes || []);
    if (patch.on === false) add("set_hvac_mode", { hvac_mode: "off" });
    else {
      if (patch.on === true || patch.mode !== undefined) {
        const m = patch.mode ?? state.mode ?? Object.keys(modes)[0];
        if (!modes[m]) bad("Unsupported mode");
        add("set_hvac_mode", { hvac_mode: modes[m] });
      }
      if (patch.target !== undefined) {
        if (patch.target < d.min || patch.target > d.max)
          bad("Target outside device range");
        const targetMode = modes[patch.mode ?? state.mode] || s.state;
        if (targetMode === "heat_cool") {
          if (
            Number.isInteger(a.supported_features) &&
            !(a.supported_features & 2)
          )
            bad("This climate device does not support temperature ranges");
          if (
            !Number.isFinite(a.target_temp_low) ||
            !Number.isFinite(a.target_temp_high)
          )
            bad("This climate device needs separate low and high targets");
          const halfRange = (a.target_temp_high - a.target_temp_low) / 2;
          const center = nativeTemperature(patch.target, a);
          if (
            halfRange <= 0 ||
            center - halfRange < nativeTemperature(d.min, a) ||
            center + halfRange > nativeTemperature(d.max, a)
          )
            bad("Target range is outside device limits");
          add("set_temperature", {
            target_temp_low: center - halfRange,
            target_temp_high: center + halfRange,
          });
        } else {
          if (
            Number.isInteger(a.supported_features) &&
            !(a.supported_features & 1)
          )
            bad(
              "This climate device does not support a single target temperature",
            );
          add("set_temperature", {
            temperature: nativeTemperature(patch.target, a),
          });
        }
      }
      if (patch.fan !== undefined) {
        if (!fans[patch.fan]) bad("Unsupported fan");
        add("set_fan_mode", { fan_mode: fans[patch.fan] });
      }
      if (patch.swing !== undefined) {
        const choices = a.swing_modes || [];
        const n =
          patch.swing === "off" ? "off" : choices.find((x) => x !== "off");
        if (!choices.includes(n)) bad("Unsupported swing");
        add("set_swing_mode", { swing_mode: n });
      }
      for (const p of ["sleep", "eco"])
        if (patch[p] !== undefined) {
          const n = patch[p] ? p : "none";
          if (!(a.preset_modes || []).includes(n)) bad("Unsupported preset");
          add("set_preset_mode", { preset_mode: n });
        }
    }
  }
  if (!out.length) bad("No supported control requested");
  return out;
}
