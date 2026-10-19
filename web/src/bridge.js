import { isServer, initializeServer, serverCall, navigateMode, showServerSettings } from './server.js';
export { isServer };
await initializeServer();
// Thin bridge to the native shell (the macOS menu bar app or the iPhone app). In a plain
// browser every call is a no-op, so the same bundle runs under `vite dev` too.

const handler = window.webkit?.messageHandlers?.house;

export const isNative = Boolean(handler);
export const isConnected = isNative || isServer;

// 'ios' inside the iPhone app (or with ?platform=ios in a browser, to work on that layout).
export const platform = new URLSearchParams(location.search).get('platform') || window.__HOUSE_BOOT__?.platform || (handler ? 'macos' : 'web');
export const isPhone = platform === 'ios' || platform === 'android' || (isServer && matchMedia('(max-width: 700px)').matches);

export function post(type, payload = {}) {
  if (isServer) {
    if (type === 'openEditor') navigateMode('editor');
    else if (type === 'openSettings') showServerSettings();
    else if (type === 'close') navigateMode('panel');
    else if (type === 'openConnection') navigateMode('editor', `service:${payload.service}`);
    return;
  }
  handler?.postMessage({ type, ...payload });
}

// A tap you can feel, on the iPhone only: 'tick' for a step of a slider, 'light' /
// 'medium' for a switch or a scene, 'error' when a device refuses a change.
export function haptic(kind = 'light') {
  if (isPhone) post('haptic', { kind });
}

// Native -> JS entry points are attached here by main.js.
export const incoming = (window.house = window.house || {});

// Request/response on top of the one-way message channel.
let nextId = 1;
const pending = new Map();

export function call(type, payload = {}) {
  if (isServer) return serverCall(type, payload);
  if (!handler) return Promise.reject(new Error('Only available inside the app'));
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    handler.postMessage({ type, callId: id, ...payload });
  });
}

incoming.reply = (id, result) => {
  const p = pending.get(id);
  if (!p) return;
  pending.delete(id);
  if (result && result.error) p.reject(Object.assign(new Error(result.error), { detail: result }));
  else p.resolve(result);
};
