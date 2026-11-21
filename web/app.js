// Triversity web flasher: C5 firmware over Web Serial (esptool-js), the FPGA
// bitstream as a download. Adapted from the C5VRX web flasher (web/app.js of
// https://github.com/Twotoz/C5VRX) by Twotoz and the C5VRX contributors: the
// download key, the bootloader handshake and the C5 watchdog reset are theirs.
import { ESPLoader, Transport } from './esptool.js';

const $ = id => document.getElementById(id);
const wait = ms => new Promise(r => setTimeout(r, ms));
const logEl = $('log');
function log(msg, cls) {
  const line = document.createElement('div');
  if (cls) line.className = cls;
  line.textContent = msg;
  logEl.appendChild(line);
  logEl.scrollTop = logEl.scrollHeight;
}
const terminal = { clean() {}, writeLine: m => log(m), write: m => log(m) };

// ---- releases: same-origin mirror (firmware/releases.json, written by the Pages
// workflow); the GitHub API is only a development fallback ----
let releases = [];
async function loadReleases() {
  const sel = $('release');
  try {
    const r = await fetch('firmware/releases.json', { cache: 'no-store' });
    if (!r.ok) throw new Error(r.status);
    releases = await r.json();
  } catch {
    try {
      const r = await fetch('https://api.github.com/repos/Twotoz/c5vrx-fpga/releases?per_page=10');
      releases = (await r.json()).map(x => ({ tag: x.tag_name, name: x.name, published_at: x.published_at,
        assets: x.assets.map(a => ({ name: a.name, url: a.browser_download_url })) }));
    } catch { releases = []; }
  }
  sel.innerHTML = '';
  if (!releases.length) {
    sel.innerHTML = '<option>No releases yet</option>';
    $('releaseInfo').textContent = 'No published build found. Flash a local file below.';
  }
  releases.forEach((rel, i) => {
    const o = document.createElement('option');
    o.value = i;
    o.textContent = `${rel.tag}${i === 0 ? ' (latest)' : ''}`;
    sel.appendChild(o);
  });
  showRelease();
}
const current = () => releases[parseInt($('release').value, 10)] || null;
const asset = (rel, name) => rel && rel.assets.find(a => a.name === name);
const assetUrl = a => a.local_url || a.url;
function showRelease() {
  const rel = current();
  const fs = asset(rel, 'triversity.fs');
  $('dlFs').href = fs ? assetUrl(fs) : '#';
  $('dlFs').toggleAttribute('aria-disabled', !fs);
  if (rel) $('releaseInfo').textContent = `${rel.name || rel.tag} · ${new Date(rel.published_at).toLocaleString()}`;
  updateButtons();
}
$('release').addEventListener('change', showRelease);

// ---- connection (C5VRX: the download key, then the ROM loader; USB reset otherwise) ----
const DOWNLOAD_KEY = 0x60;
const DOWNLOAD_ACK = 'download_boot=requested';
const LP_WDT_CONFIG0_REG = 0x600b1c00, LP_WDT_CONFIG1_REG = 0x600b1c04, LP_WDT_WPROTECT_REG = 0x600b1c18;
const LP_WDT_WKEY = 0x50d83aa1, LP_WDT_RESET_CONFIG = 0xd0000102;
let port = null, transport = null, esploader = null, busy = false;

async function sendDownloadKey(p) {
  await p.open({ baudRate: 115200 });
  try { await p.setSignals({ requestToSend: false }); await p.setSignals({ dataTerminalReady: false }); } catch { /* optional */ }
  const reader = p.readable.getReader(), writer = p.writable.getWriter();
  let seen = '', outcome = '', cancelling = false;
  const dec = new TextDecoder();
  const reading = (async () => {
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) { if (!cancelling) outcome = 'port closed'; return; }
        seen = (seen + dec.decode(value, { stream: true })).slice(-4096);
        if (seen.includes(DOWNLOAD_ACK)) { outcome = 'acknowledged'; return; }
      }
    } catch { if (!cancelling) outcome = 'port closed'; }
  })();
  try {
    await Promise.race([writer.write(new Uint8Array([DOWNLOAD_KEY])).catch(() => {}), wait(1000)]);
    await Promise.race([reading, wait(1000)]);
    if (outcome === 'acknowledged') await wait(500);
  } finally {
    cancelling = true;
    try { await Promise.race([writer.abort(), wait(500)]); } catch { /* gone */ }
    try { await Promise.race([reader.cancel(), wait(500)]); } catch { /* gone */ }
    try { reader.releaseLock(); } catch { /* reading */ }
    try { writer.releaseLock(); } catch { /* released */ }
    try { await Promise.race([p.close(), wait(1000)]); } catch { /* gone */ }
  }
  return outcome || (seen ? 'other output' : 'no reply');
}

async function handshake(p, mode) {
  class QuietTransport extends Transport {
    async connect(...args) {
      await super.connect(...args);
      try { await this.device.setSignals({ requestToSend: false }); await this.device.setSignals({ dataTerminalReady: false }); } catch { /* optional */ }
    }
  }
  transport = new QuietTransport(p);
  esploader = new ESPLoader({ transport, baudrate: parseInt($('baud').value, 10), terminal, romBaudrate: 115200, debugLogging: false });
  await esploader.main(mode);
}

async function connect() {
  if (!('serial' in navigator)) { alert('Web Serial is not available: use Chrome or Edge on a desktop.'); return; }
  busy = true; updateButtons();
  try {
    port = await navigator.serial.requestPort();
    $('status').textContent = 'Connecting… sending the download key';
    let key;
    try { key = await sendDownloadKey(port); } catch (e) { key = `not sent: ${e.message || e}`; }
    const restarted = key === 'acknowledged' || key === 'port closed';
    $('status').textContent = `Connecting… waiting for the restart (download key: ${key})`;
    await wait(2000);
    const ports = await navigator.serial.getPorts();
    if (!ports.includes(port)) throw new Error('The C5 did not come back on the same port: click Connect C5 and select it again.');
    let route = 'download key';
    try {
      await handshake(port, 'no_reset');
    } catch (e) {
      if (restarted) throw new Error(`The C5 restarted into the bootloader but did not answer (${e.message || e}). Unplug it, plug it back in and connect again.`);
      try { await transport.disconnect(); } catch { /* closed */ }
      await handshake(port, 'usb_reset');
      route = 'USB reset';
    }
    log(`Bootloader reached by ${route}.`);
    $('status').textContent = `${esploader.chip ? esploader.chip.CHIP_NAME : 'ESP32-C5'} connected · ready to flash`;
    $('btnConnect').textContent = 'Disconnect';
  } catch (e) {
    if (e?.name !== 'NotFoundError') {
      log(`Connection failed: ${e.message || e}`, 'err');
      alert(`Failed to connect: ${e.message || e}\n\nIf it keeps failing: hold BOOT on the XIAO, tap RESET, release BOOT and try again.`);
    }
    await disconnect();
  } finally { busy = false; updateButtons(); }
}

async function disconnect(msg = 'No device connected') {
  try { if (transport) await transport.disconnect(); } catch { /* gone */ }
  port = transport = esploader = null;
  $('btnConnect').textContent = 'Connect C5';
  $('status').textContent = msg;
  updateButtons();
}
$('btnConnect').addEventListener('click', () => (esploader ? disconnect() : connect()));

// ---- flashing ----
let localBin = null;
$('localFile').addEventListener('change', async e => {
  const f = e.target.files[0];
  localBin = f ? new Uint8Array(await f.arrayBuffer()) : null;
  updateButtons();
});
function updateButtons() {
  const haveFw = localBin || asset(current(), 'triversity_c5.bin');
  $('btnFlash').disabled = busy || !esploader || !haveFw;
  $('btnConnect').disabled = busy;
}
async function fetchBin(a) {
  log(`Downloading ${a.name}…`);
  const r = await fetch(assetUrl(a));
  if (!r.ok) throw new Error(`${a.name}: HTTP ${r.status}`);
  return new Uint8Array(await r.arrayBuffer());
}
async function images() {
  if (localBin) return [{ data: localBin, address: parseInt($('offset').value, 16) }];
  const rel = current();
  // offsets from the build's flasher_args.json
  const args = JSON.parse(new TextDecoder().decode(await fetchBin(asset(rel, 'flasher_args.json'))));
  const out = [];
  for (const [addr, path] of Object.entries(args.flash_files)) {
    const name = path.split('/').pop();
    const a = asset(rel, name);
    if (!a) throw new Error(`release has no ${name}`);
    out.push({ data: await fetchBin(a), address: parseInt(addr, 16) });
  }
  return out;
}
function progress(p, text) {
  $('progress').hidden = false;
  $('bar').style.width = `${p}%`;
  $('pct').textContent = text ? `${p}% · ${text}` : `${p}%`;
}
$('btnFlash').addEventListener('click', async () => {
  if (!esploader) return;
  busy = true; updateButtons(); $('logBox').open = true;
  try {
    progress(0, 'preparing');
    const files = await images();
    await esploader.writeFlash({
      fileArray: files, flashSize: '8MB', flashMode: 'dio', flashFreq: '80m',
      eraseAll: $('eraseAll').checked, compress: false,   // the C5's USB serial fails in the compressed path
      reportProgress: (i, w, t) => progress(Math.floor(w / t * 100), `image ${i + 1}/${files.length}`)
    });
    progress(100, 'done, restarting');
    let resetting = false;
    try {
      await esploader.writeReg(LP_WDT_WPROTECT_REG, LP_WDT_WKEY);
      await esploader.writeReg(LP_WDT_CONFIG1_REG, 2000);
      resetting = true;
      await esploader.writeReg(LP_WDT_CONFIG0_REG, LP_WDT_RESET_CONFIG);
    } catch { /* resetting */ }
    if (resetting) await wait(1000);
    else { try { await esploader.after('hard_reset'); } catch { /* port closed */ } }
    log('Flashing completed. Next C5: connect it and flash again.');
    await disconnect('Flashed · the C5 is restarting. Connect the next one.');
  } catch (e) {
    log(`Flashing failed: ${e.message || e}`, 'err');
    alert(`Flashing error: ${e.message || e}`);
  } finally { busy = false; updateButtons(); }
});

loadReleases();
