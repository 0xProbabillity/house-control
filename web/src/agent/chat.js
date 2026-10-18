// "Talk to your home": a chat inside the AI Access window. The user's own LLM Gateway key
// puts any model behind it — GPT, Claude, Gemini, Llama… — and the native shell (HomeChat.swift)
// runs the conversation: it calls the model, the model calls the home's tools. This file only
// draws the card; `send` carries chat.* messages to the shell, `render` takes its status back.
import { h } from '../ui/dom.js';
import { icon } from '../ui/icons.js';

export const LLM_GATEWAY_URL = 'https://llmgateway.io';
export const LLM_GATEWAY_KEYS_URL = 'https://llmgateway.io/dashboard/api-keys';

const FAMILY_NAMES = {
  llmgateway: 'LLM Gateway routers', openai: 'OpenAI', anthropic: 'Anthropic', google: 'Google', meta: 'Meta',
  xai: 'xAI', deepseek: 'DeepSeek', mistral: 'Mistral', alibaba: 'Alibaba (Qwen)', moonshot: 'Moonshot (Kimi)',
  zai: 'Z.ai (GLM)', minimax: 'MiniMax', bytedance: 'ByteDance', nvidia: 'NVIDIA', ibm: 'IBM', tencent: 'Tencent',
  inclusionai: 'inclusionAI', xiaomi: 'Xiaomi', sakana: 'Sakana', stepfun: 'StepFun', reka: 'Reka', thinkingmachines: 'Thinking Machines',
};
const familyName = (f) => FAMILY_NAMES[f] || (f ? f.charAt(0).toUpperCase() + f.slice(1) : 'Other');

// Photos travel as JPEG data URLs no wider than this: enough for a room, small enough for a request.
const PHOTO_MAX = 1280;

export function createChat({ send, open, copy }) {
  let chat = { configured: false, model: 'auto', models: [], messages: [], busy: false };
  let editingKey = false;
  let photos = [];
  let shownCount = 0;

  /* ---------- setup: the key ---------- */

  const keyInput = h('input.key-input', { type: 'password', placeholder: 'llmgtwy_…', spellcheck: 'false', autocomplete: 'off',
    onkeydown: (ev) => { if (ev.key === 'Enter') saveKey(); } });
  const keySave = h('button.primary.small', { onclick: saveKey }, icon('key', 14), 'Save key');
  const keyRemove = h('button.ghost', { onclick: () => { send('chat.key', { key: '' }); editingKey = false; keyInput.value = ''; render(chat); } }, icon('trash', 13), 'Remove key');
  const keyCancel = h('button.ghost', { onclick: () => { editingKey = false; keyInput.value = ''; render(chat); } }, 'Cancel');
  const keyError = h('p.err.hidden');
  const setup = h('div.chat-setup',
    h('p', 'One key from ', linkTo(LLM_GATEWAY_URL, 'LLM Gateway'), ' and you talk to your home with any model — GPT, Claude, Gemini, Llama, DeepSeek, Mistral and the rest — right here, no link needed.'),
    h('div.key-row', keyInput, keySave),
    h('div.key-actions', h('button.ghost', { onclick: () => open(LLM_GATEWAY_KEYS_URL) }, icon('external', 13), 'Get a key'), keyRemove, keyCancel),
    keyError,
    h('p.muted', 'The key stays on this Mac, in a file only you can read. Requests go from this Mac to api.llmgateway.io and on to the model you pick; what the model sees is what the guide shows an assistant: room and device names, their state, and your photos.'));

  function saveKey() {
    const key = keyInput.value.trim();
    if (key.length < 20 || /\s/.test(key)) {
      keyError.textContent = 'That does not look like an LLM Gateway key (llmgtwy_…).';
      keyError.classList.remove('hidden');
      return;
    }
    keyError.classList.add('hidden');
    send('chat.key', { key });
    editingKey = false;
    keyInput.value = '';
  }

  /* ---------- the conversation ---------- */

  const modelSelect = h('select.model-select', { onchange: () => send('chat.model', { model: modelSelect.value }) });
  const modelRefresh = h('button.ghost.icon-only', { title: 'Fetch the model list again', onclick: () => send('chat.models') }, icon('rotate', 13));
  const modelNote = h('span.model-note');
  const modelRow = h('div.model-row', h('label', icon('bot', 14), 'Model'), modelSelect, modelRefresh, modelNote);

  const list = h('ul.chat');
  const input = h('textarea.chat-input', { rows: 1, placeholder: 'Dim the living room to 30%…',
    oninput: autosize,
    onkeydown: (ev) => { if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); submit(); } },
    onpaste: (ev) => { const files = [...(ev.clipboardData?.files || [])].filter((f) => f.type.startsWith('image/')); if (files.length) { ev.preventDefault(); addPhotos(files); } } });
  const fileInput = h('input', { type: 'file', accept: 'image/*', multiple: true, hidden: true, onchange: () => { addPhotos([...fileInput.files]); fileInput.value = ''; } });
  const attach = h('button.chat-btn', { title: 'Attach photos of a room', onclick: () => fileInput.click() }, icon('attach', 16));
  const sendBtn = h('button.chat-btn.send', { title: 'Send (Enter)', onclick: submit }, icon('send', 16));
  const thumbs = h('div.thumbs');
  const composer = h('div.composer', thumbs, h('div.composer-row', attach, input, sendBtn, fileInput));
  const footerRow = h('div.chat-foot',
    h('button.ghost', { onclick: () => send('chat.clear') }, icon('trash', 13), 'New conversation'),
    h('button.ghost', { onclick: () => { editingKey = true; render(chat); keyInput.focus(); } }, icon('key', 13), 'Change key'));
  const conversation = h('div.chat-body', modelRow, list, composer, footerRow);

  const el = h('section.card.chat-card',
    h('div.card-head', h('span.card-title', icon('chat', 15), 'Talk to your home'),
      h('button.via', { title: 'Powered by LLM Gateway — open llmgateway.io', onclick: () => open(LLM_GATEWAY_URL) }, 'via ', h('b', 'LLM Gateway'))),
    setup, conversation);

  function autosize() {
    input.style.height = 'auto';
    input.style.height = `${Math.min(140, input.scrollHeight)}px`;
  }

  function submit() {
    const text = input.value.trim();
    if ((!text && !photos.length) || chat.busy) return;
    send('chat.send', { text, photos: photos.map((p) => p.url) });
    input.value = '';
    photos = [];
    renderThumbs();
    autosize();
  }

  async function addPhotos(files) {
    for (const file of files) {
      try { photos.push({ name: file.name, url: await shrink(file) }); } catch { /* not an image we can read */ }
    }
    renderThumbs();
  }

  function renderThumbs() {
    thumbs.replaceChildren(...photos.map((p, i) => h('div.thumb', h('img', { src: p.url, alt: p.name }),
      h('button', { title: 'Remove', onclick: () => { photos.splice(i, 1); renderThumbs(); } }, icon('close', 11, 2.4)))));
    thumbs.hidden = !photos.length;
  }
  renderThumbs();

  function renderModels() {
    const { models = [], model, loadingModels, modelsError } = chat;
    const groups = new Map();
    for (const m of models) { if (!groups.has(m.family)) groups.set(m.family, []); groups.get(m.family).push(m); }
    const ordered = [...groups.keys()].sort((a, b) => (a === 'llmgateway' ? -1 : b === 'llmgateway' ? 1 : familyName(a).localeCompare(familyName(b))));
    modelSelect.replaceChildren(...(models.length ? ordered.map((f) => h('optgroup', { label: familyName(f) },
      groups.get(f).map((m) => h('option', { value: m.id, selected: m.id === model || null }, `${m.name}${m.free ? ' · free' : ''}${m.vision ? '' : ' · no photos'}`))))
      : [h('option', { value: model, selected: true }, model)]));
    modelSelect.disabled = chat.busy || loadingModels;
    modelRefresh.classList.toggle('spin', Boolean(loadingModels));
    const picked = models.find((m) => m.id === model);
    modelNote.textContent = modelsError ? modelsError : loadingModels ? 'Loading models…'
      : picked ? `${models.length} models can run the home${picked.vision ? '' : ' · this one cannot see photos'}` : '';
    modelNote.classList.toggle('err', Boolean(modelsError));
    attach.disabled = picked ? !picked.vision : false;
  }

  function renderMessages() {
    const messages = chat.messages || [];
    if (!messages.length) {
      list.replaceChildren(h('li.empty', icon('sparkles', 16), h('span', 'Ask for anything the home can do: ', h('em', '“turn off everything except the bedroom”'), ', ', h('em', '“cool the living room to 22°”'), ', or attach photos of a room and say ', h('em', '“rebuild this in 3D”'), '.')));
      shownCount = 0;
      return;
    }
    const fresh = messages.length > shownCount;
    list.replaceChildren(...messages.map((m, i) => {
      const item = h(`li.msg.${m.role}${i >= shownCount ? '.fresh' : ''}`);
      if (m.photos) item.append(h('span.photos', icon('image', 12), `${m.photos} photo${m.photos === 1 ? '' : 's'}`));
      if (m.steps?.length) {
        item.append(h('div.steps-row', m.steps.map((s) => h(`span.step${s.ok ? '' : '.bad'}`, icon(s.ok ? 'check' : 'alert', 11, 2.4), s.title))));
        for (const s of m.steps) if (s.image) item.append(h('img.render', { src: s.image, alt: s.title }));
      }
      if (m.text) item.append(h('div.said', ...paragraphs(m.text)));
      if (m.error) item.append(h('div.said.err', icon('alert', 13), m.error));
      if (m.role === 'assistant' && !m.text && !m.error && chat.busy && i === messages.length - 1) {
        item.append(h('div.said.thinking', h('i'), h('i'), h('i')));
      }
      return item;
    }));
    shownCount = messages.length;
    if (fresh || chat.busy) list.scrollTop = list.scrollHeight;
  }

  function paragraphs(text) {
    return text.split(/\n{2,}/).map((p) => h('p', ...p.split('\n').flatMap((line, i) => (i ? [h('br'), line] : [line]))));
  }

  let wasBusy = false;
  function render(next) {
    chat = next || chat;
    const showSetup = !chat.configured || editingKey;
    setup.classList.toggle('hidden', !showSetup);
    conversation.classList.toggle('hidden', showSetup);
    keyRemove.hidden = !chat.configured;
    keyCancel.hidden = !chat.configured;
    if (!showSetup) {
      renderModels();
      renderMessages();
      sendBtn.disabled = Boolean(chat.busy);
      input.disabled = Boolean(chat.busy);
      // Back to the box once the answer is in; not on every status push, which would steal the caret.
      if (wasBusy && !chat.busy) input.focus({ preventScroll: true });
    }
    wasBusy = Boolean(chat.busy);
  }

  function linkTo(url, label) {
    return h('a', { href: url, onclick: (ev) => { ev.preventDefault(); open(url); } }, label);
  }

  return { el, render };
}

// Reads one picture and brings it down to PHOTO_MAX pixels on its long side, as a JPEG data URL.
function shrink(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      const scale = Math.min(1, PHOTO_MAX / Math.max(img.naturalWidth, img.naturalHeight));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(img.naturalWidth * scale));
      canvas.height = Math.max(1, Math.round(img.naturalHeight * scale));
      canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
      resolve(canvas.toDataURL('image/jpeg', 0.85));
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('not an image')); };
    img.src = url;
  });
}
