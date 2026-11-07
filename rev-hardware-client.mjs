#!/usr/bin/env node
// macOS CLI that runs REV Hardware Client's OS and firmware update steps for the
// Driver Hub, Control Hub, and Expansion Hub. The steps come from the main process
// of REV Hardware Client 1.7.6 (resources/app.asar, main.js). Needs no Wine,
// CrossOver, or Electron.
//
// Protocol
//   1. `adb devices` finds the device over USB. getprop gives the device type.
//        adb -s <id> shell getprop persist.ftcandroid.serialasusb   "true" means Control Hub
//        adb -s <id> shell getprop persist.rds                      "true" means Driver Hub
//   2. adb forwards two local TCP ports to the device's web server.
//        adb -s <id> forward tcp:<P>   tcp:8080   (HTTP control API)
//        adb -s <id> forward tcp:<P+1> tcp:8081   (WebSocket, unused here)
//   3. REV's public manifest names the update file
//      (https://www.revrobotics.com/content/sw/rev-hw-client/main.json, then the
//      RevHub plugin JSON). The tool downloads it over HTTPS and checks its SHA-256.
//   4. The tool POSTs the file as multipart/form-data to the device's REST API.
//        POST /uploadDriverHubOta        (Driver Hub OS update)
//        POST /uploadControlHubOta       (Control Hub OS update)
//        POST /uploadExpansionHubFirmware, then POST /performRevFirmwareUpdate
//                                         (firmware for the Control Hub itself or for
//                                          a connected Expansion Hub, chosen by serial)
//
// This path uses no native Windows binaries.
//
// Usage
//   ./rev-hardware-client.mjs list
//   ./rev-hardware-client.mjs update driver-hub-os   [--adb-id <id>]
//   ./rev-hardware-client.mjs update control-hub-os  [--adb-id <id>]
//   ./rev-hardware-client.mjs update hub-firmware    [--adb-id <id>] [--serial "(embedded)"]
//   ./rev-hardware-client.mjs discover-hubs          [--adb-id <id>]   # list serials for hub-firmware
//   ./rev-hardware-client.mjs update robot-controller-app|driver-station-app [--adb-id <id>]
//   ./rev-hardware-client.mjs update spark-max-firmware|spark-flex-firmware|servo-hub-firmware [--serial <dfu serial>]
//   ./rev-hardware-client.mjs info     [--adb-id <id>]   # installed vs latest versions
//   ./rev-hardware-client.mjs logs     [--adb-id <id>] [--out <dir>]
//   ./rev-hardware-client.mjs settings [--adb-id <id>] [--name <n>] [--password <p>] [--channel <c>]
//   ./rev-hardware-client.mjs dfu-list                  # SPARK / Servo Hub in DFU mode
//   ./rev-hardware-client.mjs version  [--check]
//
// `update` and `settings` changes contact the device only when given --yes.

import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:net';
import {
  mkdirSync,
  existsSync,
  readFileSync,
  writeFileSync,
  renameSync,
  rmSync,
  realpathSync,
} from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const MAIN_JSON_URL =
  'https://www.revrobotics.com/content/sw/rev-hw-client/main.json';
const CACHE_DIR = path.join(homedir(), '.rhc-mac-tool');
const DOWNLOADS_DIR = path.join(CACHE_DIR, 'downloads');

export const VERSION = '1.1.0';
const REPO = 'KingJayan/mac-rev-hardware-client';

const UPLOAD_URI = {
  'control-hub-os': '/uploadControlHubOta',
  'driver-hub-os': '/uploadDriverHubOta',
  'hub-firmware': '/uploadExpansionHubFirmware',
};

// android apps, installed over adb
const APPS = {
  'robot-controller-app': {
    pkg: 'com.qualcomm.ftcrobotcontroller',
    component:
      'com.qualcomm.ftcrobotcontroller/org.firstinspires.ftc.robotcontroller.internal.PermissionValidatorWrapper',
    device: 'control-hub',
  },
  'driver-station-app': {
    pkg: 'com.qualcomm.ftcdriverstation',
    component: 'com.qualcomm.ftcdriverstation/.PermissionValidatorWrapper',
    device: 'driver-hub',
  },
};

// usb dfu firmware, flashed with dfu-util
const DFU = {
  'spark-max-firmware': 'SparkMax',
  'spark-flex-firmware': 'SparkMax',
  'servo-hub-firmware': 'ServoHub',
};

const TITLES = {
  'driver-hub-os': 'Driver Hub OS',
  'control-hub-os': 'Control Hub OS',
  'hub-firmware': 'Hub Firmware',
  'robot-controller-app': 'Robot Controller app',
  'driver-station-app': 'Driver Station app',
  'spark-max-firmware': 'SPARK MAX firmware',
  'spark-flex-firmware': 'SPARK Flex firmware',
  'servo-hub-firmware': 'Servo Hub firmware',
};

function log(...args) {
  console.log(...args);
}

function die(message) {
  console.error(`Error: ${message}`);
  process.exit(1);
}

function adb(args, { adbId } = {}) {
  const fullArgs = adbId ? ['-s', adbId, ...args] : args;
  try {
    return execFileSync('adb', fullArgs, { encoding: 'utf8' });
  } catch (e) {
    die(`adb ${fullArgs.join(' ')} failed: ${e.stderr || e.message}`);
  }
}

// like adb() but returns null instead of exiting
function adbTry(args, { adbId } = {}) {
  const fullArgs = adbId ? ['-s', adbId, ...args] : args;
  try {
    return execFileSync('adb', fullArgs, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      maxBuffer: 64 * 1024 * 1024,
    });
  } catch {
    return null;
  }
}

function checkAdbAvailable() {
  try {
    execFileSync('adb', ['version'], { stdio: 'ignore' });
  } catch {
    die(
      'adb not found on PATH. Install it with: brew install android-platform-tools',
    );
  }
}

function listAdbDevices() {
  const output = adb(['devices']);
  return output
    .split('\n')
    .slice(1)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('*'))
    .map((line) => line.split(/\s+/))
    .filter(([, state]) => state === 'device')
    .map(([id]) => id);
}

function getprop(adbId, key) {
  return adb(['shell', `getprop ${key}`], { adbId }).trim();
}

function identifyDevice(adbId) {
  const isControlHub =
    getprop(adbId, 'persist.ftcandroid.serialasusb') === 'true';
  const isDriverHub = getprop(adbId, 'persist.rds') === 'true';
  if (isControlHub) return 'control-hub';
  if (isDriverHub) return 'driver-hub';
  return 'unknown';
}

async function findFreePortPair() {
  const tryPort = (port) =>
    new Promise((resolve) => {
      const srv = createServer();
      srv.once('error', () => resolve(false));
      srv.listen(port, '127.0.0.1', () => srv.close(() => resolve(true)));
    });
  for (let port = 15000; port < 15100; port += 2) {
    if ((await tryPort(port)) && (await tryPort(port + 1))) {
      return port;
    }
  }
  die('Could not find a free local port pair for adb forward');
}

const forwarded = [];

// drop our forwards on exit
process.on('exit', () => {
  for (const { adbId, port } of forwarded) {
    try {
      execFileSync('adb', ['-s', adbId, 'forward', '--remove', `tcp:${port}`], {
        stdio: 'ignore',
      });
    } catch {}
  }
});

async function forwardPorts(adbId, { quiet } = {}) {
  const port = await findFreePortPair();
  adb(['forward', `tcp:${port}`, 'tcp:8080'], { adbId });
  forwarded.push({ adbId, port });
  adb(['forward', `tcp:${port + 1}`, 'tcp:8081'], { adbId });
  forwarded.push({ adbId, port: port + 1 });
  if (!quiet) log(`Forwarded 127.0.0.1:${port} -> device:8080 (and ${port + 1} -> 8081)`);
  return port;
}

async function fetchJson(url) {
  const res = await fetch(url);
  if (!res.ok) die(`GET ${url} failed: ${res.status} ${res.statusText}`);
  return res.json();
}

const pluginCache = {};

async function getPlugin(name = 'RevHub') {
  if (pluginCache[name]) return pluginCache[name];
  const mainJson = await fetchJson(MAIN_JSON_URL);
  const plugin = mainJson.plugins.find((p) => p.name === name);
  if (!plugin?.url) die(`${name} plugin entry not found in main.json`);
  return (pluginCache[name] = await fetchJson(plugin.url));
}

async function getLatestSoftwareInfo(permanentSoftwareName) {
  const pluginJson = await getPlugin(DFU[permanentSoftwareName] ?? 'RevHub');
  const entry = pluginJson.latestSoftware.find(
    (sw) => sw.permanentSoftwareName === permanentSoftwareName,
  );
  if (!entry) die(`No latest version found for ${permanentSoftwareName}`);
  return entry;
}

async function downloadAndVerify(softwareInfo) {
  mkdirSync(DOWNLOADS_DIR, { recursive: true });
  const fileName = `${softwareInfo.permanentSoftwareName}-${softwareInfo.versionString}${path.extname(
    new URL(softwareInfo.url).pathname,
  )}`;
  const filePath = path.join(DOWNLOADS_DIR, fileName);

  if (
    existsSync(filePath) &&
    sha256Of(filePath) === softwareInfo.sha256.toLowerCase()
  ) {
    log(`Using cached, checksum-verified file: ${filePath}`);
    return filePath;
  }

  log(`Downloading ${softwareInfo.url} ...`);
  const res = await fetch(softwareInfo.url);
  if (!res.ok) die(`Download failed: ${res.status} ${res.statusText}`);
  const buffer = Buffer.from(await res.arrayBuffer());
  const partPath = `${filePath}.part`;
  writeFileSync(partPath, buffer);

  const actualSha256 = sha256Of(partPath);
  if (actualSha256 !== softwareInfo.sha256.toLowerCase()) {
    rmSync(partPath, { force: true });
    die(
      `Checksum mismatch for ${filePath}\n  expected: ${softwareInfo.sha256}\n  actual:   ${actualSha256}`,
    );
  }
  renameSync(partPath, filePath);
  log(`Downloaded and verified: ${filePath}`);
  return filePath;
}

function sha256Of(filePath) {
  return createHash('sha256')
    .update(readFileSync(filePath))
    .digest('hex')
    .toLowerCase();
}

// Minimal multipart/form-data encoder, so the tool needs no npm dependencies.
export function buildMultipartBody(fields, fileField) {
  const boundary = `----rhcmac${Date.now().toString(16)}`;
  const parts = [];
  for (const [name, value] of Object.entries(fields)) {
    parts.push(
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\n${value}\r\n`,
      ),
    );
  }
  if (fileField) {
    const { name, filename, data } = fileField;
    parts.push(
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="${name}"; filename="${filename}"\r\nContent-Type: application/octet-stream\r\n\r\n`,
      ),
    );
    parts.push(data);
    parts.push(Buffer.from('\r\n'));
  }
  parts.push(Buffer.from(`--${boundary}--\r\n`));
  return {
    body: Buffer.concat(parts),
    contentType: `multipart/form-data; boundary=${boundary}`,
  };
}

async function postMultipart(port, uploadPath, fields, fileField) {
  const { body, contentType } = buildMultipartBody(fields, fileField);
  const res = await fetch(`http://127.0.0.1:${port}${uploadPath}`, {
    method: 'POST',
    headers: { 'Content-Type': contentType },
    body,
  });
  const text = await res.text();
  if (!res.ok) die(`POST ${uploadPath} failed: ${res.status} ${text}`);
  return text;
}

async function getHubJson(port, hubPath, timeoutMs = 6000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`http://127.0.0.1:${port}/${hubPath}`, {
      signal: controller.signal,
    });
    if (!res.ok) return void 0;
    return await res.json();
  } catch {
    return void 0;
  } finally {
    clearTimeout(timeout);
  }
}

async function cmdList({ json }) {
  checkAdbAvailable();
  const ids = listAdbDevices();
  if (json) {
    log(JSON.stringify(ids.map((id) => ({ id, type: identifyDevice(id) }))));
    return;
  }
  if (ids.length === 0) {
    log('No ADB devices found. Plug in a Driver Hub or Control Hub over USB.');
    return;
  }
  for (const id of ids) {
    const type = identifyDevice(id);
    log(`${id}\t${type}`);
  }
}

async function cmdDiscoverHubs({ adbId, json }) {
  checkAdbAvailable();
  const id = adbId ?? requireSingleDevice();
  const type = identifyDevice(id);
  if (type !== 'control-hub') {
    die(
      `discover-hubs only applies to a Control Hub (device ${id} is a ${type})`,
    );
  }
  const port = await forwardPorts(id);
  const modules = await getHubJson(port, 'revHubsAvailableForUpdate');
  if (!modules)
    die(
      "Could not reach the Control Hub's local API (is the Robot Controller app running?)",
    );
  const list = modules.modules ?? [];
  if (json) {
    log(JSON.stringify(list));
    return;
  }
  log('Hubs available for firmware update:');
  for (const m of list) {
    log(
      `  serial=${m.serialNumber}\tmoduleAddress=${m.moduleAddress}\tfirmware=${m.formattedFirmwareVersionString}`,
    );
  }
}

const RC_IP = '192.168.43.1';

function sh(cmd, args) {
  try {
    return execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch (e) {
    return e.stdout || '';
  }
}

function wifiInterface() {
  const out = sh('networksetup', ['-listallhardwareports']);
  const m = out.match(/Hardware Port: Wi-Fi\nDevice: (\S+)/);
  return m ? m[1] : 'en0';
}

function pingHost(host) {
  const out = sh('ping', ['-c', '3', '-t', '4', '-q', host]);
  const loss = out.match(/([\d.]+)% packet loss/);
  const rtt = out.match(/= [\d.]+\/([\d.]+)\//);
  return {
    host,
    reachable: !!rtt,
    lossPercent: loss ? Number(loss[1]) : 100,
    avgMs: rtt ? Number(rtt[1]) : null,
  };
}

async function webServerUp(host) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 3000);
  try {
    await fetch(`http://${host}:8080/`, { signal: controller.signal });
    return true;
  } catch {
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

async function getWifiInfo() {
  const iface = wifiInterface();
  const summary = sh('ipconfig', ['getsummary', iface]);
  const ssidMatch = summary.match(/^\s*SSID : (.+)$/m);
  const ssid =
    ssidMatch && ssidMatch[1] !== '<redacted>' ? ssidMatch[1].trim() : null;
  const ip = sh('ipconfig', ['getifaddr', iface]).trim() || null;
  const routerMatch = summary.match(/^\s*Router : (\S+)$/m);
  const gateway = routerMatch ? routerMatch[1] : null;
  const ping = pingHost(RC_IP);
  const web = ping.reachable ? await webServerUp(RC_IP) : false;
  return {
    interface: iface,
    connected: !!ip,
    ssid,
    ssidHidden: !!ssidMatch && !ssid,
    ip,
    gateway,
    // rc hotspots hand out 192.168.43.x
    onRcNetwork: gateway === RC_IP || (ip ?? '').startsWith('192.168.43.'),
    rcAddress: RC_IP,
    ping,
    webServer: web,
  };
}

async function cmdWifi({ json }) {
  const w = await getWifiInfo();
  if (json) {
    log(JSON.stringify(w));
    return;
  }
  log(`Interface:   ${w.interface}`);
  log(`Connected:   ${w.connected ? 'yes' : 'no'}`);
  log(
    `Network:     ${w.ssid ?? (w.ssidHidden ? '(hidden by macOS, needs location permission)' : 'unknown')}`,
  );
  log(`IP address:  ${w.ip ?? '-'}`);
  log(`Gateway:     ${w.gateway ?? '-'}`);
  log(`RC network:  ${w.onRcNetwork ? 'yes' : 'no'}`);
  log(
    `Ping ${w.rcAddress}: ${w.ping.reachable ? `${w.ping.avgMs} ms, ${w.ping.lossPercent}% loss` : 'no reply'}`,
  );
  log(`RC web server: ${w.webServer ? 'up' : 'not reachable'}`);
}

function packageVersion(adbId, pkg) {
  const out = adbTry(['shell', `dumpsys package ${pkg}`], { adbId }) ?? '';
  const name = out.match(/versionName=(\S+)/);
  const code = out.match(/versionCode=(\d+)/);
  if (!name || !code) return null;
  return { version: name[1], versionCode: Number(code[1]) };
}

// "1.8.2" or "HW: 20, Maj: 1, Min: 8, Eng: 2"
export function parseFirmware(s) {
  if (!s) return null;
  const m =
    s.match(/Maj:\s*(\d+),\s*Min:\s*(\d+),\s*Eng:\s*(\d+)/) ??
    s.match(/(\d+)\.(\d+)\.(\d+)/);
  return m ? m.slice(1, 4).map(Number) : null;
}

export function newer(latest, installed) {
  for (let i = 0; i < 3; i++) {
    if ((latest[i] ?? 0) !== (installed[i] ?? 0))
      return (latest[i] ?? 0) > (installed[i] ?? 0);
  }
  return false;
}

async function getDeviceInfo(id) {
  const type = identifyDevice(id);
  const prop = (k) => adbTry(['shell', `getprop ${k}`], { adbId: id })?.trim() || null;
  const kind = type === 'driver-hub' ? 'driverhub' : 'controlhub';
  const info = {
    id,
    type,
    serial: prop('ro.serialno'),
    osVersion: prop(`ro.${kind}.os.version`),
    osVersionNum: Number(prop(`ro.${kind}.os.versionnum`)) || null,
    android: prop('ro.build.version.release'),
    apps: {},
    subHubs: [],
    rcReachable: false,
    updates: [],
  };
  for (const [name, a] of Object.entries(APPS)) {
    info.apps[name] = packageVersion(id, a.pkg);
  }
  if (type === 'unknown') return info;

  if (type === 'control-hub') {
    const port = await forwardPorts(id, { quiet: true });
    const mods = await getHubJson(port, 'revHubsAvailableForUpdate');
    info.rcReachable = !!mods;
    info.subHubs = mods?.modules ?? [];
  }

  const plugin = await getPlugin('RevHub');
  const latest = (n) => plugin.latestSoftware.find((s) => s.permanentSoftwareName === n);
  const push = (target, installed, available, extra = {}) => {
    const l = latest(target);
    if (!l) return;
    info.updates.push({
      target,
      title: TITLES[target],
      installed,
      latest: l.versionString,
      updateAvailable: available(l),
      ...extra,
    });
  };

  const os = type === 'driver-hub' ? 'driver-hub-os' : 'control-hub-os';
  push(os, info.osVersion, (l) => info.osVersionNum != null && l.versionCode > info.osVersionNum);
  const app = type === 'driver-hub' ? 'driver-station-app' : 'robot-controller-app';
  const a = info.apps[app];
  push(app, a?.version ?? null, (l) => !a || l.versionCode > a.versionCode);
  for (const m of info.subHubs) {
    const fw = parseFirmware(m.formattedFirmwareVersionString);
    push('hub-firmware', fw ? fw.join('.') : m.formattedFirmwareVersionString ?? null,
      (l) => !!fw && newer(parseFirmware(l.versionString) ?? [0, 0, 0], fw),
      { serial: m.serialNumber });
  }
  return info;
}

async function cmdInfo({ adbId, json }) {
  checkAdbAvailable();
  const info = await getDeviceInfo(adbId ?? requireSingleDevice());
  if (json) {
    log(JSON.stringify(info));
    return;
  }
  log(`Device:     ${info.id} (${info.type})`);
  log(`Serial:     ${info.serial ?? '-'}`);
  log(`OS:         ${info.osVersion ?? '-'}   Android ${info.android ?? '-'}`);
  for (const [n, v] of Object.entries(info.apps)) {
    log(`${TITLES[n].padEnd(22)}${v ? `${v.version} (${v.versionCode})` : 'not installed'}`);
  }
  if (info.type === 'control-hub' && !info.rcReachable) {
    log('Robot Controller app not reachable, so hub firmware versions are unknown.');
  }
  log('\nUpdates:');
  for (const u of info.updates) {
    log(
      `  ${(u.title + (u.serial && u.serial !== '(embedded)' ? ` ${u.serial}` : '')).padEnd(32)}` +
        `${(u.installed ?? 'none').padEnd(14)} -> ${u.latest}${u.updateAvailable ? '   update available' : ''}`,
    );
  }
}

const LOG_PREFIXES = [
  'robotControllerLog.txt',
  'driverStationLog.txt',
  'DriverStationLog.txt',
  'UpdaterLog.txt',
  'WifiLog.txt',
];

async function cmdLogs({ adbId, out, json }) {
  checkAdbAvailable();
  const id = adbId ?? requireSingleDevice();
  const info = await getDeviceInfo(id);
  const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
  const dir =
    out ?? path.join(homedir(), 'Downloads', `rev-logs-${info.serial ?? id}-${stamp}`);
  mkdirSync(path.join(dir, 'matchlogs'), { recursive: true });

  const files = (adbTry(['shell', 'ls -1 /sdcard/'], { adbId: id }) ?? '')
    .split('\n')
    .map((f) => f.trim())
    .filter((f) => LOG_PREFIXES.some((p) => f.startsWith(p)));
  const pulled = [];
  for (const f of files) {
    if (adbTry(['pull', `/sdcard/${f}`, path.join(dir, f)], { adbId: id }) !== null) {
      pulled.push(f);
      log(`Pulled ${f}`);
    }
  }
  const matches = (adbTry(['shell', 'ls -1 /sdcard/FIRST/matchlogs'], { adbId: id }) ?? '')
    .split('\n')
    .map((f) => f.trim())
    .filter((f) => f && !f.includes('No such file'));
  for (const f of matches) {
    if (adbTry(['pull', `/sdcard/FIRST/matchlogs/${f}`, path.join(dir, 'matchlogs', f)], { adbId: id }) !== null) {
      pulled.push(`matchlogs/${f}`);
    }
  }
  if (matches.length) log(`Pulled ${matches.length} match logs`);
  const logcat = adbTry(['logcat', '-d'], { adbId: id });
  if (logcat) {
    writeFileSync(path.join(dir, 'logcat.txt'), logcat);
    pulled.push('logcat.txt');
    log('Saved logcat.txt');
  }
  writeFileSync(path.join(dir, 'device-info.json'), JSON.stringify(info, null, 2));
  if (json) log(JSON.stringify({ dir, files: pulled }));
  else log(`Saved ${pulled.length} files to ${dir}`);
}

async function cmdSettings({ adbId, name, password, channel, yes, json }) {
  checkAdbAvailable();
  const id = adbId ?? requireSingleDevice();
  const type = identifyDevice(id);
  if (type !== 'control-hub') die(`settings only applies to a Control Hub (device ${id} is a ${type})`);
  const port = await forwardPorts(id, { quiet: true });
  const rc = await getHubJson(port, 'js/rcInfo.json');
  if (!rc) die("Could not reach the Control Hub's local API (is the Robot Controller app running?)");
  const current = {
    name: rc.deviceName,
    password: rc.passphrase,
    channel: rc.currentChannel?.name ?? null,
    channels: (rc.availableChannels ?? []).map((c) => ({
      name: c.name,
      displayName: c.displayName,
      band: c.band,
      overlaps: !!c.overlapsWithOtherChannels,
    })),
    supports5Ghz: !!rc.supports5GhzAp,
    rcVersion: rc.rcVersion ?? null,
    activeConfig: rc.activeConfigName ?? null,
  };

  if (name === undefined && password === undefined && channel === undefined) {
    if (json) return log(JSON.stringify(current));
    log(`Name:      ${current.name}`);
    log(`Password:  ${'•'.repeat(current.password?.length ?? 0)}  (use --json to see it)`);
    log(`Channel:   ${current.channel ?? 'auto'}`);
    log(`Channels:  ${current.channels.filter((c) => !c.overlaps).map((c) => c.name).join(', ')}`);
    return;
  }

  // same checks as the hub's own manage page
  const newName = (name ?? current.name).trim();
  if (newName.length < 2 || newName.length > 32) die('Name must be 2 to 32 characters');
  if (/\s/.test(newName)) die('Name must not contain spaces');
  if (password !== undefined && (password.length < 8 || password.length > 63))
    die('Password must be 8 to 63 characters');
  if (channel !== undefined && !current.channels.some((c) => c.name === channel))
    die(`Unknown channel ${channel}. Run settings to see the list.`);

  const params = new URLSearchParams({ name: newName });
  if (password !== undefined) params.set('password', password);
  if (channel !== undefined) params.set('channelName', channel);

  if (!yes) {
    log(`DRY RUN (pass --yes to apply). Would set name=${newName}` +
      (password !== undefined ? ' and a new password' : '') +
      (channel !== undefined ? ` channel=${channel}` : ''));
    return;
  }
  const res = await fetch(`http://127.0.0.1:${port}/changeNetworkSettings`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: params.toString(),
  }).catch(() => null);
  // the hub may drop the connection while it restarts wifi
  if (res && !res.ok) die(`Settings failed to apply: ${res.status} ${await res.text()}`);
  log('Settings sent. The hub restarts its Wi‑Fi; reconnect to the new network.');
}

function checkDfuUtil() {
  if (spawnSync('dfu-util', ['--version'], { stdio: 'ignore' }).error) {
    die('dfu-util not found on PATH. Install it with: brew install dfu-util');
  }
}

export function parseDfuList(out) {
  const seen = new Map();
  for (const line of out.split('\n')) {
    const m = line.match(/Found DFU: \[([0-9a-f]{4}):([0-9a-f]{4})\].*alt=(\d+).*serial="([^"]*)"/i);
    if (!m || m[3] !== '0') continue;
    seen.set(m[4], { serial: m[4], vid: m[1], pid: m[2] });
  }
  return [...seen.values()];
}

function listDfu() {
  const r = spawnSync('dfu-util', ['-l'], { encoding: 'utf8' });
  return parseDfuList(`${r.stdout ?? ''}\n${r.stderr ?? ''}`);
}

async function cmdDfuList({ json }) {
  checkDfuUtil();
  const list = listDfu();
  if (json) return log(JSON.stringify(list));
  if (!list.length) {
    log('No devices in DFU mode. Hold the device button while plugging in USB.');
    return;
  }
  for (const d of list) log(`${d.serial}\t${d.vid}:${d.pid}`);
}

function dfu(args) {
  log(`dfu-util ${args.join(' ')}`);
  const r = spawnSync('dfu-util', args, { stdio: ['ignore', 'inherit', 'inherit'] });
  return r.status ?? 1;
}

async function cmdDfuUpdate(name, { serial, yes }) {
  checkDfuUtil();
  const list = listDfu();
  let sn = serial;
  if (!sn) {
    if (list.length === 0) die('No devices in DFU mode. Hold the device button while plugging in USB.');
    if (list.length > 1) die(`Multiple DFU devices (${list.map((d) => d.serial).join(', ')}). Pass --serial.`);
    sn = list[0].serial;
  }
  const info = await getLatestSoftwareInfo(name);
  log(`Latest ${name}: version ${info.versionString} (versionCode ${info.versionCode})`);
  const file = await downloadAndVerify(info);
  if (!yes) {
    log(`\nDRY RUN (pass --yes to flash). Would flash ${file} to DFU device ${sn}`);
    return;
  }
  if (!list.some((d) => d.serial === sn)) die(`DFU device ${sn} not found`);
  // flex needs its boot bank fixed after flashing, so it stays in dfu
  const flex = name === 'spark-flex-firmware';
  const args = ['--alt', '0', '--download', file, '--serial', sn];
  if (!flex) args.push('-s', ':leave');
  if (dfu(args) !== 0) die('dfu-util failed to flash the firmware');
  if (flex) {
    const opt = path.join(tmpdir(), `rhc-optbytes-${process.pid}.bin`);
    const base = ['--alt', '1', '--dfuse-address', '0x1fff7800'];
    if (dfu([...base, '--upload', opt, '--serial', sn]) !== 0) die('Could not read option bytes');
    const b = readFileSync(opt);
    b[2] &= 239;
    b[6] |= 16;
    writeFileSync(opt, b);
    // rhc ignores this exit code too, the device resets mid write
    dfu([...base, '--download', opt, '--serial', sn]);
    rmSync(opt, { force: true });
  }
  log(`Firmware update succeeded: ${name} -> ${info.versionString}`);
}

async function cmdVersion({ check, json }) {
  if (!check) return log(json ? JSON.stringify({ current: VERSION }) : VERSION);
  let latest = null;
  let url = `https://github.com/${REPO}/releases`;
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'rev-hub-updater' },
    });
    if (res.ok) {
      const r = await res.json();
      latest = String(r.tag_name ?? '').replace(/^v/, '') || null;
      url = r.html_url ?? url;
    }
  } catch {}
  const cur = VERSION.split('.').map(Number);
  const lat = latest?.split('.').map(Number);
  const updateAvailable = !!lat && lat.every((n) => !Number.isNaN(n)) && newer(lat, cur);
  if (json) return log(JSON.stringify({ current: VERSION, latest, updateAvailable, url }));
  log(`Current: ${VERSION}`);
  log(`Latest:  ${latest ?? 'no releases found'}`);
  if (updateAvailable) log(`Update available: ${url}`);
}

function requireSingleDevice() {
  const ids = listAdbDevices();
  if (ids.length === 0) die('No ADB devices found.');
  if (ids.length > 1)
    die(`Multiple ADB devices found (${ids.join(', ')}). Pass --adb-id <id>.`);
  return ids[0];
}

async function cmdUpdate(permanentSoftwareName, flags) {
  if (DFU[permanentSoftwareName]) return cmdDfuUpdate(permanentSoftwareName, flags);
  if (APPS[permanentSoftwareName]) return cmdAppUpdate(permanentSoftwareName, flags);
  return cmdHubUpdate(permanentSoftwareName, flags);
}

async function cmdAppUpdate(name, { adbId, yes }) {
  checkAdbAvailable();
  const app = APPS[name];
  const id = adbId ?? requireSingleDevice();
  const type = identifyDevice(id);
  log(`Device ${id} identified as: ${type}`);
  if (type !== app.device) die(`${name} goes on a ${app.device} (device ${id} is a ${type})`);
  const before = packageVersion(id, app.pkg);
  log(`Installed: ${before ? `${before.version} (versionCode ${before.versionCode})` : 'not installed'}`);
  const info = await getLatestSoftwareInfo(name);
  log(`Latest ${name}: version ${info.versionString} (versionCode ${info.versionCode})`);
  const file = await downloadAndVerify(info);
  if (!yes) {
    log(`\nDRY RUN (pass --yes to install). Would install ${file} on device ${id}`);
    return;
  }
  const remote = `/data/local/tmp/${path.basename(file)}`;
  log('Copying APK to the device...');
  adb(['push', file, remote], { adbId: id });
  log('Installing...');
  const out = adb(['shell', `pm install -g -r -d ${remote}`], { adbId: id }).trim();
  adbTry(['shell', `rm ${remote}`], { adbId: id });
  if (!out.includes('Success')) die(`Install failed: ${out}`);
  adbTry(['shell', `am start -n ${app.component} -a android.intent.action.MAIN -c android.intent.category.LAUNCHER`], { adbId: id });
  log(`Install succeeded: ${name} -> ${info.versionString}`);
}

async function cmdHubUpdate(permanentSoftwareName, { adbId, serial, yes }) {
  checkAdbAvailable();
  if (!UPLOAD_URI[permanentSoftwareName]) {
    die(`Unknown update target: ${permanentSoftwareName}`);
  }
  const id = adbId ?? requireSingleDevice();
  const type = identifyDevice(id);
  log(`Device ${id} identified as: ${type}`);

  if (permanentSoftwareName === 'driver-hub-os' && type !== 'driver-hub') {
    die(
      `driver-hub-os update requires a Driver Hub (device ${id} is a ${type})`,
    );
  }
  if (
    (permanentSoftwareName === 'control-hub-os' ||
      permanentSoftwareName === 'hub-firmware') &&
    type !== 'control-hub'
  ) {
    die(
      `${permanentSoftwareName} update requires a Control Hub (device ${id} is a ${type})`,
    );
  }

  const softwareInfo = await getLatestSoftwareInfo(permanentSoftwareName);
  log(
    `Latest ${permanentSoftwareName}: version ${softwareInfo.versionString} (versionCode ${softwareInfo.versionCode})`,
  );

  const filePath = await downloadAndVerify(softwareInfo);

  if (!yes) {
    log(
      `\nDRY RUN (pass --yes to flash). Would upload ${filePath} to device ${id} ` +
        `via ${UPLOAD_URI[permanentSoftwareName]}` +
        (permanentSoftwareName === 'hub-firmware'
          ? ` and trigger performRevFirmwareUpdate for serial=${serial ?? '(embedded)'}`
          : ''),
    );
    return;
  }

  const port = await forwardPorts(id);
  const fileData = readFileSync(filePath);
  const fileName = path.basename(filePath);

  if (permanentSoftwareName === 'hub-firmware') {
    log('Uploading firmware file to Control Hub...');
    const uploadedFileName = (
      await postMultipart(
        port,
        UPLOAD_URI[permanentSoftwareName],
        { force: 'true' },
        {
          name: 'file',
          filename: fileName,
          data: fileData,
        },
      )
    ).trim();
    log(`Hub accepted upload as: ${uploadedFileName}`);
    const targetSerial = serial ?? '(embedded)';
    log(`Triggering firmware update for serial=${targetSerial} ...`);
    const response = await postMultipart(port, '/performRevFirmwareUpdate', {
      serialNumber: targetSerial,
      filename: uploadedFileName,
    });
    let json;
    try {
      json = JSON.parse(response);
    } catch {
      die(`Unexpected response from /performRevFirmwareUpdate: ${response}`);
    }
    if (json.success) {
      log(
        `Firmware update succeeded: ${permanentSoftwareName} -> ${softwareInfo.versionString}`,
      );
    } else {
      die(json.errorMessage ?? 'Firmware could not be updated');
    }
  } else {
    log(`Uploading OS update to ${type}...`);
    const response = await postMultipart(
      port,
      UPLOAD_URI[permanentSoftwareName],
      { force: 'true' },
      {
        name: 'file',
        filename: fileName,
        data: fileData,
      },
    );
    let json;
    try {
      json = JSON.parse(response);
    } catch {
      log(`Upload complete. Raw response: ${response}`);
      return;
    }
    log(`Upload complete: ${JSON.stringify(json)}`);
    log('The device will apply the update and reboot on its own.');
  }
}

const VALUE_FLAGS = {
  '--adb-id': 'adbId',
  '--serial': 'serial',
  '--name': 'name',
  '--password': 'password',
  '--channel': 'channel',
  '--out': 'out',
};

function parseArgs(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--yes') flags.yes = true;
    else if (arg === '--json') flags.json = true;
    else if (arg === '--check') flags.check = true;
    else if (VALUE_FLAGS[arg]) {
      const value = argv[++i];
      if (value === undefined || (arg !== '--password' && value.startsWith('--')))
        die(`${arg} needs a value`);
      flags[VALUE_FLAGS[arg]] = value;
    } else positional.push(arg);
  }
  return { positional, flags };
}

async function main() {
  const { positional, flags } = parseArgs(process.argv.slice(2));
  const [command, target] = positional;

  switch (command) {
    case 'list':
      return cmdList(flags);
    case 'wifi':
      return cmdWifi(flags);
    case 'discover-hubs':
      return cmdDiscoverHubs(flags);
    case 'info':
      return cmdInfo(flags);
    case 'logs':
      return cmdLogs(flags);
    case 'settings':
      return cmdSettings(flags);
    case 'dfu-list':
      return cmdDfuList(flags);
    case 'version':
      return cmdVersion(flags);
    case 'update':
      if (!target) die(`Usage: update <${Object.keys(TITLES).join('|')}>`);
      return cmdUpdate(target, flags);
    default:
      log(
        'Usage:\n' +
          '  rev-hardware-client.mjs list [--json]\n' +
          '  rev-hardware-client.mjs discover-hubs [--adb-id <id>] [--json]\n' +
          '  rev-hardware-client.mjs wifi [--json]\n' +
          '  rev-hardware-client.mjs update driver-hub-os|control-hub-os|hub-firmware [--adb-id <id>] [--serial <serial>] [--yes]\n' +
          '  rev-hardware-client.mjs update robot-controller-app|driver-station-app [--adb-id <id>] [--yes]\n' +
          '  rev-hardware-client.mjs update spark-max-firmware|spark-flex-firmware|servo-hub-firmware [--serial <dfu serial>] [--yes]\n' +
          '  rev-hardware-client.mjs info [--adb-id <id>] [--json]\n' +
          '  rev-hardware-client.mjs logs [--adb-id <id>] [--out <dir>] [--json]\n' +
          '  rev-hardware-client.mjs settings [--adb-id <id>] [--name <name>] [--password <pw>] [--channel <channel>] [--yes] [--json]\n' +
          '  rev-hardware-client.mjs dfu-list [--json]\n' +
          '  rev-hardware-client.mjs version [--check] [--json]\n',
      );
      process.exit(command ? 1 : 0);
  }
}

// works with spaces and symlinks in the path
const isMain = (() => {
  try {
    return (
      import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
    );
  } catch {
    return false;
  }
})();

if (isMain) {
  main().catch((e) => die(e.stack || e.message));
}
