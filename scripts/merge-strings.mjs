// Adds (or overrides) translation keys in jellyfin-web's src/strings/*.json.
// Usage: node merge-strings.mjs <jellyfin-web/src/strings> <patches/jellyfin-web/strings>
//
// Strings are merged instead of patched so that translation updates upstream
// (Weblate rewrites these files often) never make the patch fail to apply.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [target, source] = process.argv.slice(2);

if (!target || !source) {
    console.error('Usage: node merge-strings.mjs <target strings dir> <source strings dir>');
    process.exit(2);
}

for (const file of readdirSync(source).filter(name => name.endsWith('.json'))) {
    const targetFile = join(target, file);
    const strings = JSON.parse(readFileSync(targetFile, 'utf8'));
    const additions = JSON.parse(readFileSync(join(source, file), 'utf8'));

    Object.assign(strings, additions);
    writeFileSync(targetFile, JSON.stringify(strings, null, 4) + '\n');
    console.log(`${file}: ${Object.keys(additions).length} strings merged`);
}
