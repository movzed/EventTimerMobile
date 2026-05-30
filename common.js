// Event Timer — shared logic for the web (PWA) version.
// Replaces Electron IPC with BroadcastChannel + localStorage so Control and
// Display can run as two tabs/windows on the same device (e.g. an iPad).
(function (global) {
  'use strict';

  const CHANNEL = 'event-timer';
  const KEY_PRESETS = 'et_presets';
  const KEY_LOGO = 'et_logo';       // base64 data URL of the current logo
  const KEY_STATE = 'et_state';     // last broadcast state (cold-load paint)
  const KEY_SETTINGS = 'et_settings'; // operator settings (warn/urgent/time/mode)

  // ── format helpers ────────────────────────────────────────────────────────
  function fmt(s) {
    const a = Math.abs(Math.round(s));
    const m = Math.floor(a / 60);
    const sec = a % 60;
    return String(m).padStart(2, '0') + ':' + String(sec).padStart(2, '0');
  }

  // Clock string HH:MM:SS from a Date (local time).
  function clockStr(d) {
    return (d || new Date()).toTimeString().slice(0, 8);
  }

  // Parse "MM:SS" or a bare minute count into seconds.
  function parse(str) {
    str = String(str).trim();
    if (str.includes(':')) {
      const parts = str.split(':');
      const m = Math.max(0, parseInt(parts[0], 10) || 0);
      const s = Math.max(0, parseInt(parts[1], 10) || 0);
      return m * 60 + Math.min(59, s);
    }
    return Math.max(0, parseInt(str, 10) || 0) * 60;
  }

  // ── storage helpers ───────────────────────────────────────────────────────
  function loadJSON(key, fallback) {
    try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback; }
    catch (e) { return fallback; }
  }
  function saveJSON(key, val) {
    try { localStorage.setItem(key, JSON.stringify(val)); } catch (e) { /* quota */ }
  }
  function loadStr(key) { try { return localStorage.getItem(key); } catch (e) { return null; } }
  function saveStr(key, val) {
    try { if (val == null) localStorage.removeItem(key); else localStorage.setItem(key, val); }
    catch (e) { /* quota */ }
  }

  const Presets = {
    all() { return loadJSON(KEY_PRESETS, []); },
    save(name, time) {
      const list = this.all();
      const idx = list.findIndex(p => p.name === name);
      if (idx >= 0) list[idx] = { name, time }; else list.push({ name, time });
      saveJSON(KEY_PRESETS, list);
      return list;
    },
    remove(name) {
      const list = this.all().filter(p => p.name !== name);
      saveJSON(KEY_PRESETS, list);
      return list;
    }
  };

  const Logo = {
    get() { return loadStr(KEY_LOGO); },
    set(dataUrl) { saveStr(KEY_LOGO, dataUrl); }
  };

  // ── message bus: BroadcastChannel, with a localStorage-event fallback ──────
  function makeBus() {
    let bc = null;
    try { bc = new BroadcastChannel(CHANNEL); } catch (e) { bc = null; }
    const listeners = [];
    if (bc) {
      bc.onmessage = (ev) => listeners.forEach(fn => fn(ev.data));
    } else {
      window.addEventListener('storage', (ev) => {
        if (ev.key === '__et_bus__' && ev.newValue) {
          try { const m = JSON.parse(ev.newValue); listeners.forEach(fn => fn(m)); }
          catch (e) { /* ignore */ }
        }
      });
    }
    return {
      post(msg) {
        if (bc) { bc.postMessage(msg); }
        else { saveStr('__et_bus__', JSON.stringify(Object.assign({ _t: Date.now() }, msg))); }
      },
      on(fn) { listeners.push(fn); }
    };
  }

  // ── timestamp-based timer model ───────────────────────────────────────────
  // Authoritative time is derived from `endAt` while running, so the Display
  // stays accurate even if the Control tab is throttled in the background.
  function TimerModel() {
    this.totalSecs = 25 * 60;
    this.timeLeft = this.totalSecs; // valid while paused/stopped
    this.running = false;
    this.endAt = 0;                 // ms epoch when the countdown hits 0 (real wall-clock)
    this.speed = 1;                 // 1 = normal, 1.1 = fast mode (consumes time 10% faster)
  }
  // Displayed seconds = real time to endAt, scaled by speed. With speed > 1 the
  // shown integer still ticks 1-by-1 but reaches 0 in less real time.
  TimerModel.prototype.remaining = function () {
    if (this.running) return Math.max(0, Math.round((this.endAt - Date.now()) / 1000 * this.speed));
    return this.timeLeft;
  };
  TimerModel.prototype.setTime = function (secs) {
    this.totalSecs = secs;
    this.timeLeft = secs;
    this.running = false;
  };
  TimerModel.prototype.start = function () {
    let left = this.remaining();
    if (left <= 0) left = this.totalSecs;
    this.endAt = Date.now() + Math.round(left / this.speed * 1000);
    this.running = true;
  };
  TimerModel.prototype.pause = function () {
    this.timeLeft = this.remaining();
    this.running = false;
  };
  TimerModel.prototype.reset = function () {
    this.timeLeft = this.totalSecs;
    this.running = false;
  };
  // Change rate. While running, re-anchor endAt so the shown time doesn't jump.
  TimerModel.prototype.setSpeed = function (factor) {
    if (this.running) {
      const left = this.remaining();
      this.speed = factor;
      this.endAt = Date.now() + Math.round(left / this.speed * 1000);
    } else {
      this.speed = factor;
    }
  };

  global.ET = {
    CHANNEL, KEY_PRESETS, KEY_LOGO, KEY_STATE, KEY_SETTINGS,
    fmt, clockStr, parse,
    loadJSON, saveJSON, loadStr, saveStr,
    Presets, Logo, makeBus, TimerModel
  };
})(window);
