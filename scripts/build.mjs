import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
const out = path.join(root, 'dist');
await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });
await cp(path.join(root, 'site'), out, { recursive: true });
const html = await readFile(path.join(out, 'index.html'), 'utf8');
for (const match of html.matchAll(/(?:src|href)="(\/(?:assets\/[^"#]+|styles\.css|app\.js))"/g)) {
  await readFile(path.join(out, match[1]));
}
await writeFile(path.join(out, 'robots.txt'), 'User-agent: *\nAllow: /\nSitemap: https://menusprite.prerakgada.in/sitemap.xml\n');
await writeFile(path.join(out, 'sitemap.xml'), '<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://menusprite.prerakgada.in/</loc></url></urlset>');
console.log('Built static MenuSprite site; referenced local assets verified.');
