// The web UI's text in the app's language. The English text is the key, as in the native
// String Catalogs: t('All on') looks it up in the language's dictionary (web/src/locales/*.json)
// and falls back to the English. `{name}` placeholders are filled from `vars`:
//   t('{count} of {total} on', { count: 2, total: 5 })
// A text that changes with a number takes its forms: tn(n, '{n} light', '{n} lights'). The
// dictionary keeps every form the language has (one, few, many, other), keyed by the English
// "other" form.
//
// One English word can mean two things ("Off" as a state and as an airflow position, "Fan" as a
// mode and as the fan-speed control): tc(context, text) looks up "context|text" instead, so each
// gets its own translation, and falls back to the English text: tc('ac mode', 'Auto').
// The contexts in use: 'ac mode', 'fan speed', 'airflow', 'demo' (names in the bundled demo
// plans, translated when one of those is shown, never in a person's own plan).
//
// A text with `**…**` around a part is drawn with that part in bold (richText in ui/dom.js);
// the translation keeps the markers around the matching part.
//
// The keys in use are listed by tools/l10n/web-keys.mjs (web/src/locales/en.keys.json);
// `--check` reports what each dictionary is missing. Keys are literal strings: never build one
// with + or ${}; pass numbers and names as {placeholders}.
//
// The language comes from the native app (__HOUSE_BOOT__.lang), which knows what the user
// chose; in a browser ?lang=de or the browser's own language picks it.

import ja from './locales/ja.json';
import fr from './locales/fr.json';
import es from './locales/es.json';
import de from './locales/de.json';
import it from './locales/it.json';
import el from './locales/el.json';
import tr from './locales/tr.json';
import zhHant from './locales/zh-Hant.json';
import ru from './locales/ru.json';

const DICTIONARIES = { ja, fr, es, de, it, el, tr, 'zh-Hant': zhHant, ru };
export const LANGUAGES = ['en', 'ja', 'fr', 'es', 'de', 'it', 'el', 'tr', 'zh-Hant', 'ru'];

/** One of LANGUAGES for a language tag ("de-AT" → "de", "zh-TW" → "zh-Hant"). */
export function matchLanguage(tag) {
  if (!tag) return null;
  const t = String(tag).replace('_', '-');
  if (/^zh-(Hant|TW|HK|MO)/i.test(t)) return 'zh-Hant';
  if (/^zh/i.test(t)) return null; // Simplified Chinese is not one of ours
  return LANGUAGES.find((l) => t.toLowerCase() === l.toLowerCase() || t.toLowerCase().startsWith(`${l.toLowerCase()}-`)) || null;
}

function pickLanguage() {
  const boot = typeof window !== 'undefined' ? window.__HOUSE_BOOT__?.lang : null;
  if (boot) return matchLanguage(boot) || 'en';
  const query = typeof location !== 'undefined' ? new URLSearchParams(location.search).get('lang') : null;
  if (query) return matchLanguage(query) || 'en';
  for (const tag of (typeof navigator !== 'undefined' && navigator.languages) || []) {
    const found = matchLanguage(tag);
    if (found) return found;
  }
  return 'en';
}

export const lang = pickLanguage();
const dict = DICTIONARIES[lang] || {};
// The BCP 47 locale for Intl (dates, numbers) that goes with `lang`.
export const locale = lang === 'zh-Hant' ? 'zh-TW' : lang;
const plurals = new Intl.PluralRules(locale);

if (typeof document !== 'undefined') document.documentElement.lang = lang === 'zh-Hant' ? 'zh-Hant-TW' : lang;

const fill = (text, vars) => (vars ? text.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k]) : m)) : text);

/** `text` in the app's language. */
export function t(text, vars) {
  const found = dict[text];
  return fill(typeof found === 'string' && found ? found : text, vars);
}

/** `text` as meant in `context` (the dictionary's "context|text"), else the English `text`. */
export function tc(context, text, vars) {
  const found = dict[`${context}|${text}`];
  return fill(typeof found === 'string' && found ? found : text, vars);
}

/** The form of `other` that goes with `n` ({n} is filled in, with `vars`). */
export function tn(n, one, other, vars) {
  const all = { n: formatNumber(n), ...vars };
  const found = dict[other];
  // A language without plural forms (Japanese, Chinese) may keep a single string.
  if (typeof found === 'string' && found) return fill(found, all);
  if (found && typeof found === 'object') {
    const form = found[plurals.select(n)] ?? found.other;
    if (form) return fill(form, all);
  }
  return fill(n === 1 ? one : other, all);
}

const numberFormats = new Map();
/** `n` as the language writes it ("23,5" in German); `digits` fixes the decimals shown. */
export function formatNumber(n, digits) {
  let f = numberFormats.get(digits);
  if (!f) {
    f = new Intl.NumberFormat(locale, digits == null ? {} : { minimumFractionDigits: digits, maximumFractionDigits: digits });
    numberFormats.set(digits, f);
  }
  return f.format(n);
}

/** A time span for a countdown: "45 min", "1 h 30 min" in the app's language. */
export function formatDuration(minutes) {
  const m = Math.max(0, Math.round(minutes));
  const h = Math.floor(m / 60);
  const rest = m % 60;
  try {
    const parts = h ? { hours: h, ...(rest ? { minutes: rest } : {}) } : { minutes: m };
    // Intl.DurationFormat is in Safari 16.4+ and Chrome 129+; older views get the plain form below.
    if (Intl.DurationFormat) return new Intl.DurationFormat(locale, { style: 'short' }).format(parts);
  } catch { /* fall through */ }
  if (!h) return t('{n} min', { n: m });
  return rest ? t('{h} h {m} min', { h, m: rest }) : t('{h} h', { h });
}
