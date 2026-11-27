// Browser-specific plan loading and localization.
import { ConfigError, levelsOf as sharedLevelsOf, normalize as sharedNormalize } from '@house-control/visuals/config';
import { t, tc } from './i18n.js';

export * from '@house-control/visuals/config';

export function levelsOf(raw) {
  return sharedLevelsOf(raw, t);
}

export function normalize(raw) {
  return sharedNormalize(raw, t);
}

// The demo homes that come with the app (web/public/plans) are written in English. Shown in
// another language their names are too (tc('demo', …), keys taken from those files by
// tools/l10n/web-keys.mjs); a person's own plan ("custom") is never translated.
export const DEMO_PLANS = ['home', 'studio', 'house'];

function translateDemo(raw) {
  const plan = structuredClone(raw);
  const name = (item) => { if (item && typeof item.name === 'string') item.name = tc('demo', item.name); }; // l10n-dynamic
  name(plan);
  for (const key of ['levels', 'rooms', 'lights', 'acs', 'scenes']) if (Array.isArray(plan[key])) plan[key].forEach(name);
  return plan;
}

// The plan exactly as written on disk (the editor works on this form).
export async function loadRawConfig() {
  const boot = window.__HOUSE_BOOT__;
  // The native app hands over the plan itself for the person's own home (and for a demo the
  // iPhone's editor opens); `plan` says which one it is.
  if (boot?.config) return DEMO_PLANS.includes(boot.plan) ? translateDemo(boot.config) : boot.config;
  const plan = (boot?.plan !== 'custom' && boot?.plan) || new URLSearchParams(location.search).get('plan') || 'home';
  const res = await fetch(`./plans/${plan}.json`);
  if (!res.ok) throw new ConfigError(t('Plan "{plan}" not found (HTTP {status})', { plan, status: res.status }));
  let json;
  try {
    json = await res.json();
  } catch (e) {
    throw new ConfigError(t('Plan "{plan}" is not valid JSON: {error}', { plan, error: e.message }));
  }
  return DEMO_PLANS.includes(plan) ? translateDemo(json) : json;
}

export async function loadConfig() {
  return normalize(await loadRawConfig());
}
