#!/usr/bin/env node
// The web UI's translation keys (web/src/i18n.js): every t('…'), tc('context', '…') and
// tn(n, '…one', '…other') in web/src and the shared plan parser, plus the names in the bundled demo plans (shown through
// tc('demo', name)), written to web/src/locales/en.keys.json for translators.
//
//   node tools/l10n/web-keys.mjs          extract and write en.keys.json
//   node tools/l10n/web-keys.mjs --check  also report, per language, the keys its dictionary is
//                                          missing, the ones no longer used and placeholders that
//                                          do not match ({name} in the key but not in the text)
//
// Exits with 1 when a call is not a plain literal (a variable, `${}` in a template literal, a
// string glued with +) or, with --check, when a dictionary is not complete and clean. A call
// that is meant to take a computed key (the demo names) carries an `l10n-dynamic` comment.
// agent/tools.js and agent/plan-edit.js talk to AI assistants and stay English: not scanned.

import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SRC = join(ROOT, 'web', 'src');
const SHARED_CONFIG = join(ROOT, 'web', 'packages', 'visuals', 'src', 'config.js');
const PLANS = join(ROOT, 'web', 'public', 'plans');
const LOCALES = join(SRC, 'locales');
const OUT = join(LOCALES, 'en.keys.json');
const LANGUAGES = ['ja', 'fr', 'es', 'de', 'it', 'el', 'tr', 'zh-Hant', 'ru'];
const SKIP = new Set(['agent/tools.js', 'agent/plan-edit.js']);

// What a translator cannot tell from the English alone.
const NOTES = {
  'Off': 'State of a lamp or an AC (switched off). The airflow position is "airflow|Off".',
  'On': 'State of a lamp or an AC (switched on); also a scene rule ("turn it on").',
  'airflow|Off': 'AC louvre position: fixed, not swinging. Not the power state.',
  'airflow|Swing': 'AC louvre position: sweeping up and down.',
  'ac mode|Fan': 'AC mode: fan only, no cooling or heating.',
  'ac mode|Auto': 'AC mode: picks cooling or heating by itself.',
  'ac mode|Dry': 'AC mode: dehumidifying.',
  'fan speed|Auto': 'AC fan speed chosen by the unit.',
  'fan speed|Fan': 'Short label (iPhone) of the AC fan-speed control; "Fan speed" on wider screens.',
  'Floor': 'A storey of the building (ground floor, first floor), not the flooring.',
  'Floors': 'Storeys of the building.',
  'All': 'Room filter: every room of the home.',
  'Home': 'The person\'s home (also the default name of a new plan).',
  'Idle': 'An AC that is on but not running right now (its thermostat is satisfied).',
  'AC': 'Short for air conditioner.',
  '{n} of {total} on': 'Lamps switched on, out of all lamps in the room or home.',
  '**{n} of {total}** lights on': 'Keep the ** markers around the part drawn in bold.',
  '**No** lights on': 'Keep the ** markers around the part drawn in bold.',
  'Room {temp}°': 'The temperature measured in the room.',
  'Room **{temp}°C**': 'The temperature measured in the room. Keep the ** markers.',
  '{mode} {temp}°': 'AC mode and set temperature, e.g. "Cool 23°".',
  '{name}: {message}': 'A device name and the error it reported.',
  'Spots': 'Ceiling spotlights (a type of light fixture).',
  'Sleep': 'AC sleep mode.',
  'Eco Mode': 'AC energy-saving mode.',
  'Live': 'The AI Access link is running.',
  'now': 'Time of an activity entry: just now.',
  'X': 'Coordinate axis.',
  'Head, m': 'Window head: the height of the top of the window, in metres.',
  'Sill, m': 'Window sill height, in metres.',
  'Use': 'Button: use this server address.',
  'Pair': 'Button: pair with this Hue Bridge.',
  '{name} copy': 'Name of a duplicated scene.',
  '{room} AC': 'Default name of a new air conditioner in a room.',
  '3D': 'Button that shows the 3D view.',
  'Plan': 'Button that shows the 2D floor plan.',
};
const NOTE_PREFIX = [
  ['demo|', 'Name in a bundled demo home (room, lamp, AC, scene, floor or the home itself).'],
  ['icon|', 'Name of an icon a scene can have.'],
];

/* ---------- a small JavaScript tokenizer: strings, templates, regexes and comments ---------- */

function tokenize(src) {
  const tokens = [];
  let i = 0;
  let line = 1;
  const push = (type, value, start, startLine, extra = {}) => tokens.push({ type, value, start, line: startLine, ...extra });
  const regexAllowed = () => {
    const prev = tokens[tokens.length - 1];
    if (!prev) return true;
    if (prev.type === 'punct') return !/^[)\]}]$/.test(prev.value);
    return prev.type === 'ident' && /^(return|typeof|case|of|in|instanceof|new|delete|void|throw|else|do|yield|await)$/.test(prev.value);
  };
  const readString = (quote) => {
    let out = '';
    i++;
    while (i < src.length && src[i] !== quote) {
      if (src[i] === '\\') {
        const c = src[i + 1];
        const map = { n: '\n', t: '\t', r: '\r', '0': '\0', b: '\b', f: '\f', v: '\v' };
        if (c === 'u') {
          const m = /^\{([0-9a-f]+)\}|^([0-9a-f]{4})/i.exec(src.slice(i + 2));
          out += String.fromCodePoint(parseInt(m[1] || m[2], 16));
          i += 2 + m[0].length;
          continue;
        }
        if (c === 'x') { out += String.fromCharCode(parseInt(src.slice(i + 2, i + 4), 16)); i += 4; continue; }
        if (c === '\n') { line++; i += 2; continue; }
        out += map[c] ?? c;
        i += 2;
        continue;
      }
      if (src[i] === '\n') line++;
      out += src[i++];
    }
    i++;
    return out;
  };
  // Template literals: the text up to the closing ` or the next `${`. What is inside `${…}` is
  // tokenized like any other code (a t() call in there is a key too); `templates` holds the
  // template tokens whose `${` is open, with the depth of the braces inside it.
  const templates = [];
  const readTemplatePart = (tok) => {
    while (i < src.length && src[i] !== '`') {
      if (src[i] === '\\') { tok.value += src[i + 1] === '`' ? '`' : src[i + 1] === 'n' ? '\n' : src[i + 1]; i += 2; continue; }
      if (src[i] === '$' && src[i + 1] === '{') {
        tok.interpolated = true;
        tok.value += '${…}';
        i += 2;
        templates.push({ tok, depth: 0 });
        return;
      }
      if (src[i] === '\n') line++;
      tok.value += src[i++];
    }
    i++; // the closing `
  };

  while (i < src.length) {
    const c = src[i];
    const start = i;
    const startLine = line;
    if (c === '\n') { line++; i++; continue; }
    if (/\s/.test(c)) { i++; continue; }
    if (c === '/' && src[i + 1] === '/') {
      const end = src.indexOf('\n', i);
      push('comment', src.slice(i, end < 0 ? src.length : end), start, startLine);
      i = end < 0 ? src.length : end;
      continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      const end = src.indexOf('*/', i + 2);
      const text = src.slice(i, end + 2);
      line += (text.match(/\n/g) || []).length;
      i = end + 2;
      continue;
    }
    if (c === '\'' || c === '"') { const value = readString(c); push('string', value, start, startLine); continue; }
    if (c === '`') {
      push('template', '', start, startLine, { interpolated: false });
      i++;
      readTemplatePart(tokens[tokens.length - 1]);
      continue;
    }
    if (templates.length && (c === '{' || c === '}')) {
      const open = templates[templates.length - 1];
      if (c === '}' && !open.depth) { templates.pop(); i++; readTemplatePart(open.tok); continue; }
      open.depth += c === '{' ? 1 : -1;
    }
    if (c === '/' && regexAllowed()) {
      i++;
      let inClass = false;
      while (i < src.length) {
        const r = src[i];
        if (r === '\\') { i += 2; continue; }
        if (r === '[') inClass = true;
        else if (r === ']') inClass = false;
        else if (r === '/' && !inClass) break;
        else if (r === '\n') break;
        i++;
      }
      i++;
      while (/[a-z]/i.test(src[i] || '')) i++;
      push('regex', src.slice(start, i), start, startLine);
      continue;
    }
    if (/[A-Za-z_$]/.test(c)) {
      while (/[\w$]/.test(src[i] || '')) i++;
      push('ident', src.slice(start, i), start, startLine);
      continue;
    }
    if (/\d/.test(c)) {
      while (/[\w.]/.test(src[i] || '')) i++;
      push('number', src.slice(start, i), start, startLine);
      continue;
    }
    // Multi-character operators matter only for "?." and "=>"; one character each is enough.
    if (c === '?' && src[i + 1] === '.') { push('punct', '?.', start, startLine); i += 2; continue; }
    push('punct', c, start, startLine);
    i++;
  }
  return tokens;
}

/* ---------- the calls ---------- */

const keys = new Map(); // key -> entry
const problems = [];
const lineHas = (src, line, text) => (src.split('\n')[line - 1] || '').includes(text);

function addKey(key, entry) {
  const had = keys.get(key);
  if (!had) { keys.set(key, entry); return; }
  if (entry.plural && had.plural && had.one !== entry.one) {
    problems.push(`${entry.at}: "${key}" has the singular "${entry.one}" here but "${had.one}" at ${had.at}`);
  }
  if (Boolean(entry.plural) !== Boolean(had.plural)) {
    problems.push(`${entry.at}: "${key}" is used both with tn() and without (first at ${had.at}); give one of them other words`);
  }
}

function scanFile(file) {
  const rel = relative(ROOT, file).split('\\').join('/');
  const where = (tok) => `${rel}:${tok.line}`;
  const src = readFileSync(file, 'utf8');
  const tokens = tokenize(src).filter((tok) => tok.type !== 'comment');
  // A literal argument: a string, or a template without ${}. Anything else is reported.
  const literal = (k, fn) => {
    const tok = tokens[k];
    const next = tokens[k + 1];
    if (!tok) return null;
    const dynamic = lineHas(src, tok.line, 'l10n-dynamic');
    if (tok.type === 'template' && tok.interpolated) {
      if (!dynamic) problems.push(`${where(tok)}: ${fn}() with \${} in a template literal — use a {placeholder} instead`);
      return null;
    }
    if (tok.type !== 'string' && tok.type !== 'template') {
      if (!dynamic) problems.push(`${where(tok)}: ${fn}() called with a non-literal (${tok.value}…) — keys must be literal strings`);
      return null;
    }
    if (next?.type === 'punct' && next.value === '+') {
      problems.push(`${where(tok)}: ${fn}() with a string glued together with + — use one literal with {placeholders}`);
      return null;
    }
    return tok.value;
  };
  // Index of the token after the next top-level comma from k on (the first argument of tn).
  const afterArg = (k) => {
    let depth = 0;
    for (; k < tokens.length; k++) {
      const v = tokens[k].type === 'punct' ? tokens[k].value : null;
      if (v === '(' || v === '[' || v === '{') depth++;
      else if (v === ')' || v === ']' || v === '}') { if (!depth) return -1; depth--; }
      else if (v === ',' && !depth) return k + 1;
    }
    return -1;
  };
  const comma = (k) => tokens[k]?.type === 'punct' && tokens[k].value === ',';

  for (let k = 0; k < tokens.length - 1; k++) {
    const tok = tokens[k];
    if (tok.type !== 'ident' || !['t', 'tc', 'tn'].includes(tok.value)) continue;
    if (!(tokens[k + 1].type === 'punct' && tokens[k + 1].value === '(')) continue;
    const prev = tokens[k - 1];
    if (prev && ((prev.type === 'punct' && (prev.value === '.' || prev.value === '?.')) || (prev.type === 'ident' && prev.value === 'function'))) continue;
    const fn = tok.value;
    const at = where(tok);
    if (fn === 't') {
      const text = literal(k + 2, fn);
      if (text != null) addKey(text, { key: text, at });
    } else if (fn === 'tc') {
      const context = literal(k + 2, fn);
      if (context == null) continue;
      if (!comma(k + 3)) { problems.push(`${at}: tc() needs (context, text)`); continue; }
      const text = literal(k + 4, fn);
      if (text != null) addKey(`${context}|${text}`, { key: `${context}|${text}`, at, context, text });
    } else {
      const j = afterArg(k + 2);
      if (j < 0) { problems.push(`${at}: tn() needs (n, one, other)`); continue; }
      const one = literal(j, fn);
      if (one == null) continue;
      if (!comma(j + 1)) { problems.push(`${at}: tn() needs (n, one, other)`); continue; }
      const other = literal(j + 2, fn);
      if (other != null) addKey(other, { key: other, at, plural: true, one });
    }
  }
}

function walk(dir) {
  for (const name of readdirSync(dir).sort()) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) { if (name !== 'locales') walk(path); continue; }
    if (!name.endsWith('.js')) continue;
    if (SKIP.has(relative(SRC, path).split('\\').join('/'))) continue;
    scanFile(path);
  }
}

// The bundled demo homes: their names go through tc('demo', name) (config.js translateDemo).
function scanPlans() {
  for (const name of readdirSync(PLANS).filter((n) => n.endsWith('.json')).sort()) {
    const plan = JSON.parse(readFileSync(join(PLANS, name), 'utf8'));
    const at = `web/public/plans/${name}`;
    const names = [plan.name, ...['levels', 'rooms', 'lights', 'acs', 'scenes'].flatMap((key) => (plan[key] || []).map((x) => x?.name))];
    for (const text of names) if (typeof text === 'string' && text) addKey(`demo|${text}`, { key: `demo|${text}`, at, context: 'demo', text });
  }
}

walk(SRC);
scanFile(SHARED_CONFIG);
scanPlans();

const placeholders = (s) => [...String(s).matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
const entries = [...keys.values()].sort((a, b) => a.key.localeCompare(b.key, 'en')).map((e) => {
  const out = { key: e.key, at: e.at };
  if (e.plural) { out.plural = true; out.one = e.one; }
  if (e.context) { out.context = e.context; out.text = e.text; }
  const vars = placeholders(e.plural ? `${e.key} ${e.one}` : e.text ?? e.key).filter((v, i, a) => a.indexOf(v) === i);
  if (vars.length) out.placeholders = vars;
  const note = NOTES[e.key] || NOTE_PREFIX.find(([p]) => e.key.startsWith(p))?.[1];
  if (note) out.note = note;
  return out;
});
writeFileSync(OUT, `${JSON.stringify(entries, null, 2)}\n`);

const plural = entries.filter((e) => e.plural).length;
const contexts = [...new Set(entries.filter((e) => e.context).map((e) => e.context))];
console.log(`${entries.length} keys (${plural} plural, ${entries.filter((e) => e.context).length} with a context: ${contexts.join(', ')}) → ${relative(ROOT, OUT)}`);
for (const p of problems) console.error(`  ✗ ${p}`);

let failed = problems.length > 0;

if (process.argv.includes('--check')) {
  const known = new Map(entries.map((e) => [e.key, e]));
  for (const lang of LANGUAGES) {
    let dict;
    try { dict = JSON.parse(readFileSync(join(LOCALES, `${lang}.json`), 'utf8')); } catch (e) {
      console.error(`${lang}: cannot read ${lang}.json (${e.message})`);
      failed = true;
      continue;
    }
    const missing = [];
    const bad = [];
    for (const e of entries) {
      const value = dict[e.key];
      const forms = value && typeof value === 'object' ? Object.values(value) : [value];
      if (value == null || value === '' || (typeof value === 'object' && !value.other)) { missing.push(e.key); continue; }
      const want = (e.placeholders || []).filter((v) => !(e.plural && v === 'n')).join();
      for (const form of forms) {
        if (typeof form !== 'string') { bad.push(`${e.key}: not text`); continue; }
        const got = placeholders(form).filter((v, i, a) => a.indexOf(v) === i && !(e.plural && v === 'n')).join();
        if (got !== want) bad.push(`"${e.key}": placeholders {${got}} instead of {${want}} in "${form}"`);
        if (/\*\*/.test(e.key) !== /\*\*/.test(form)) bad.push(`"${e.key}": the ** bold markers are missing in "${form}"`);
      }
    }
    const stale = Object.keys(dict).filter((k) => !known.has(k));
    const done = entries.length - missing.length;
    console.log(`${lang.padEnd(8)} ${done}/${entries.length} translated${missing.length ? `, ${missing.length} missing` : ''}${stale.length ? `, ${stale.length} stale` : ''}${bad.length ? `, ${bad.length} wrong` : ''}`);
    const show = (label, list) => {
      if (!list.length) return;
      console.log(`  ${label}:`);
      for (const k of list.slice(0, 40)) console.log(`    ${k}`);
      if (list.length > 40) console.log(`    … and ${list.length - 40} more`);
    };
    if (process.argv.includes('--verbose') || missing.length <= 40) show('missing', missing);
    show('stale (no longer used)', stale);
    show('wrong', bad);
    if (missing.length || stale.length || bad.length) failed = true;
  }
}

process.exit(failed ? 1 : 0);
