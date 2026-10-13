import {
  createElement, Power, Sun, Sofa, Film, Moon, DoorOpen, LampCeiling, LampFloor, LampDesk, Lightbulb,
  Snowflake, Flame, Droplets, Fan, Wind, Leaf, ChevronDown, ChevronLeft, Plus, Minus, Thermometer,
  SlidersHorizontal, Check, House, Settings2, AirVent, Sparkles, FolderOpen, Plug, Lamp, SunDim, SunMedium,
  Tv, BedDouble, Palette, RefreshCw, X,
} from 'lucide';

const ICONS = {
  power: Power, sun: Sun, sofa: Sofa, film: Film, moon: Moon, door: DoorOpen,
  ceiling: LampCeiling, pendant: Lamp, spots: Lightbulb, floor: LampFloor, table: LampDesk, strip: Sparkles,
  cool: Snowflake, heat: Flame, dry: Droplets, fan: Fan, auto: RefreshCw, wind: Wind, leaf: Leaf,
  down: ChevronDown, back: ChevronLeft, plus: Plus, minus: Minus, thermo: Thermometer,
  sliders: SlidersHorizontal, check: Check, home: House, settings: Settings2, ac: AirVent,
  folder: FolderOpen, plug: Plug, dim: SunDim, bright: SunMedium, tv: Tv, bed: BedDouble,
  palette: Palette, sparkles: Sparkles, close: X,
};

export function icon(name, size = 18, stroke = 1.8) {
  const el = createElement(ICONS[name] || ICONS.sparkles);
  el.setAttribute('width', size);
  el.setAttribute('height', size);
  el.setAttribute('stroke-width', stroke);
  el.classList.add('icon');
  return el;
}
