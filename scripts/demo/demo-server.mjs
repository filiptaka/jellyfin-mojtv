// Drives a local, throwaway Jellyfin test server (http://127.0.0.1:8096) for the demo library.
//
//   node demo-server.mjs setup <library folder> <watched.txt>   first-run wizard, library, scan, watched state
//   node demo-server.mjs latest [seasons] [episodes]             set the two options (on/off) and print Recently Added
//
// The demo user is "demo"; its random password is kept in the file named by DEMO_PASSWORD_FILE
// (created by setup). This is only for a throwaway local server bound to 127.0.0.1.
import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

const BASE = 'http://127.0.0.1:8096';
const CLIENT = 'MediaBrowser Client="demo-script", Device="cli", DeviceId="demo-script", Version="1.0"';
const PASSWORD_FILE = process.env.DEMO_PASSWORD_FILE;
let token = '';

function password() {
    if (!PASSWORD_FILE) throw new Error('Set DEMO_PASSWORD_FILE');
    if (!existsSync(PASSWORD_FILE)) writeFileSync(PASSWORD_FILE, randomBytes(12).toString('base64url'));
    return readFileSync(PASSWORD_FILE, 'utf8').trim();
}

async function api(method, path, body) {
    const response = await fetch(BASE + path, {
        method,
        headers: {
            Authorization: token ? `${CLIENT}, Token="${token}"` : CLIENT,
            ...(body === undefined ? {} : { 'Content-Type': 'application/json' })
        },
        body: body === undefined ? undefined : JSON.stringify(body)
    });
    if (!response.ok) throw new Error(`${method} ${path} -> ${response.status} ${await response.text()}`);
    const text = await response.text();
    return text ? JSON.parse(text) : null;
}

async function login() {
    const auth = await api('POST', '/Users/AuthenticateByName', { Username: 'demo', Pw: password() });
    token = auth.AccessToken;
    return auth.User.Id;
}

async function waitForScan() {
    for (;;) {
        const tasks = await api('GET', '/ScheduledTasks?isHidden=false');
        const scan = tasks.find(t => t.Key === 'RefreshLibrary');
        if (scan && scan.State === 'Idle') return;
        await new Promise(resolve => setTimeout(resolve, 1000));
    }
}

async function showsLibraryId() {
    const folders = await api('GET', '/Library/VirtualFolders');
    return folders.find(f => f.Name === 'Shows').ItemId;
}

async function setup(libraryPath, watchedFile) {
    await api('POST', '/Startup/Configuration', { UICulture: 'en-US', MetadataCountryCode: 'US', PreferredMetadataLanguage: 'en' });
    await api('GET', '/Startup/User');
    await api('POST', '/Startup/User', { Name: 'demo', Password: password() });
    await api('POST', '/Startup/Complete');
    const userId = await login();

    await api('POST', '/System/Configuration/metadata', { UseFileCreationTimeForDateAdded: true });
    const noFetchers = type => ({ Type: type, MetadataFetchers: [], MetadataFetcherOrder: [], ImageFetchers: [], ImageFetcherOrder: [] });
    await api('POST', '/Library/VirtualFolders?name=Shows&collectionType=tvshows&refreshLibrary=false', {
        LibraryOptions: {
            PathInfos: [{ Path: libraryPath }],
            EnableRealtimeMonitor: false,
            TypeOptions: ['Series', 'Season', 'Episode'].map(noFetchers)
        }
    });
    await api('POST', '/Library/Refresh');
    await new Promise(resolve => setTimeout(resolve, 3000));
    await waitForScan();

    const watched = new Set(readFileSync(watchedFile, 'utf8').replace(/^﻿/, '').split(/\r?\n/).filter(Boolean).map(p => p.toLowerCase()));
    const episodes = await api('GET', `/Items?userId=${userId}&recursive=true&includeItemTypes=Episode&fields=Path&limit=2000`);
    let marked = 0;
    for (const episode of episodes.Items) {
        if (watched.has(episode.Path.toLowerCase())) {
            await api('POST', `/UserPlayedItems/${episode.Id}?userId=${userId}`);
            marked++;
        }
    }
    console.log(`Library scanned: ${episodes.Items.length} episodes, ${marked} marked as watched`);
}

async function latest(seasons, episodes) {
    const userId = await login();
    if (seasons !== undefined) {
        const config = await api('GET', '/System/Configuration');
        config.DisplayLatestSeasons = seasons === 'on';
        config.DisplayLatestEpisodes = episodes === 'on';
        await api('POST', '/System/Configuration', config);
    }
    const config = await api('GET', '/System/Configuration');
    const items = await api('GET', `/Items/Latest?userId=${userId}&parentId=${await showsLibraryId()}&limit=16`);
    console.log(`DisplayLatestSeasons=${config.DisplayLatestSeasons} DisplayLatestEpisodes=${config.DisplayLatestEpisodes}`);
    for (const item of items) {
        const what = item.Type === 'Episode' ? `S${item.ParentIndexNumber}:E${item.IndexNumber}` : item.Type === 'Season' ? item.Name : '';
        console.log(`  ${item.Type.padEnd(7)} ${(item.SeriesName ?? item.Name).padEnd(20)} ${what.padEnd(9)} unwatched=${item.UserData?.UnplayedItemCount ?? '-'}`);
    }
}

const [command, ...args] = process.argv.slice(2);
if (command === 'setup') await setup(args[0], args[1]);
else if (command === 'latest') await latest(args[0], args[1]);
else console.error('Usage: node demo-server.mjs setup <library> <watched.txt> | latest [on|off] [on|off]');
