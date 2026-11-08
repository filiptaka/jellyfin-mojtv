// Captures the PR screenshots from the local demo server (see demo-server.mjs) with a headless
// Chromium browser (Edge or Chrome) started with --remote-debugging-port=9333.
//
//   node capture-screenshots.mjs <output dir>      needs DEMO_PASSWORD_FILE
//
// Saves recently-added-before.png (both options on, the 12.x behaviour), recently-added-after.png
// (both off) and display-settings.png, at twice the pixel density.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';

const BASE = 'http://127.0.0.1:8096';
const DEVTOOLS = 'http://127.0.0.1:9333';
const CLIENT = 'MediaBrowser Client="capture-script", Device="cli", DeviceId="capture-script", Version="1.0"';
const out = process.argv[2];
if (!out) throw new Error('Usage: node capture-screenshots.mjs <output dir>');
mkdirSync(out, { recursive: true });

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let token = '';

async function api(method, path, body) {
    const response = await fetch(BASE + path, {
        method,
        headers: {
            Authorization: token ? `${CLIENT}, Token="${token}"` : CLIENT,
            ...(body === undefined ? {} : { 'Content-Type': 'application/json' })
        },
        body: body === undefined ? undefined : JSON.stringify(body)
    });
    if (!response.ok) throw new Error(`${method} ${path} -> ${response.status}`);
    const text = await response.text();
    return text ? JSON.parse(text) : null;
}

async function setOptions(seasons, episodes) {
    const config = await api('GET', '/System/Configuration');
    config.DisplayLatestSeasons = seasons;
    config.DisplayLatestEpisodes = episodes;
    await api('POST', '/System/Configuration', config);
}

const auth = await api('POST', '/Users/AuthenticateByName', {
    Username: 'demo',
    Pw: readFileSync(process.env.DEMO_PASSWORD_FILE, 'utf8').trim()
});
token = auth.AccessToken;
const info = await api('GET', '/System/Info/Public');

// DevTools protocol over a plain WebSocket.
const target = await (await fetch(`${DEVTOOLS}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
let nextId = 1;
const pending = new Map();
ws.onmessage = ({ data }) => {
    const message = JSON.parse(data);
    const call = pending.get(message.id);
    if (!call) return;
    pending.delete(message.id);
    if (message.error) call.reject(new Error(JSON.stringify(message.error)));
    else call.resolve(message.result);
};
const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = nextId++;
    const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`${method} timed out`));
    }, 20000);
    pending.set(id, {
        resolve: value => { clearTimeout(timer); resolve(value); },
        reject: error => { clearTimeout(timer); reject(error); }
    });
    ws.send(JSON.stringify({ id, method, params }));
});
async function evaluate(expression) {
    const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
    return result.result.value;
}
async function waitFor(expression, timeout = 30000) {
    for (const end = Date.now() + timeout; Date.now() < end; await sleep(250)) {
        if (await evaluate(expression).catch(() => false)) return;
    }
    throw new Error('Timed out waiting for: ' + expression);
}

await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 2, mobile: false });
await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'dark' }] });

// Sign in through the login form (a token made by another client is not accepted by the web client).
await send('Page.navigate', { url: `${BASE}/web/#/login` });
await waitFor(`!!document.querySelector('#txtManualPassword')?.offsetParent`);
await evaluate(`(() => {
    document.querySelector('#txtManualName').value = 'demo';
    document.querySelector('#txtManualPassword').value = ${JSON.stringify(readFileSync(process.env.DEMO_PASSWORD_FILE, 'utf8').trim())};
    document.querySelector('.manualLoginForm button[type=submit]').click();
    return true;
})()`);
await waitFor(`location.hash.startsWith('#/home')`);
void info;

async function open(hash) {
    // The web client keeps query results in IndexedDB; empty that cache (deleting the database
    // would block the client's own connection) and load the page fresh.
    console.log(`opening ${hash}`);
    await evaluate(`new Promise(resolve => {
        const request = indexedDB.open('keyval-store');
        request.onerror = () => resolve(false);
        request.onsuccess = () => {
            const db = request.result;
            if (!db.objectStoreNames.contains('keyval')) { db.close(); resolve(false); return; }
            const tx = db.transaction('keyval', 'readwrite');
            tx.objectStore('keyval').clear();
            tx.oncomplete = tx.onerror = () => { db.close(); resolve(true); };
        };
    })`);
    await send('Page.navigate', { url: `${BASE}/web/#${hash}` });
    await sleep(300);
    await send('Page.reload', { ignoreCache: true });
    await sleep(2000);
}

async function capture(elementExpression, file) {
    await evaluate(`(${elementExpression}).scrollIntoView({ block: 'center' }), true`);
    await sleep(1000);
    const box = await evaluate(`(() => { const r = (${elementExpression}).getBoundingClientRect(); return { x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height }; })()`);
    const shot = await send('Page.captureScreenshot', { format: 'png', clip: { ...box, scale: 1 } });
    writeFileSync(`${out}/${file}`, Buffer.from(shot.data, 'base64'));
    console.log(`${file}: ${Math.round(box.width * 2)}x${Math.round(box.height * 2)}`);
}

const latestRow = `[...document.querySelectorAll('.verticalSection')].find(s => s.querySelector('.sectionTitle')?.textContent.includes('Recently Added'))`;
const latestLoaded = `(() => { const s = ${latestRow}; const images = s ? [...s.querySelectorAll('.cardImageContainer')] : []; return images.length >= 8 && images.every(i => i.style.backgroundImage); })()`;

for (const [seasons, episodes, file] of [[true, true, 'recently-added-before.png'], [false, false, 'recently-added-after.png']]) {
    await setOptions(seasons, episodes);
    await open('/home');
    await waitFor(latestLoaded);
    await sleep(1500);
    await capture(latestRow, file);
}

await open('/dashboard/libraries/display');
await waitFor(`!!document.querySelector('input[name=DisplayLatestEpisodes]')`);
await sleep(1000);
await capture(`document.querySelector('#libraryDisplayPage form')`, 'display-settings.png');

ws.close();
await fetch(`${DEVTOOLS}/json/close/${target.id}`);
