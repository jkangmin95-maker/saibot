import { cp, mkdir, rm, readdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = join(root, 'public');
const dest = join(root, 'dist');

await rm(dest, { recursive: true, force: true });
await mkdir(dest, { recursive: true });

async function copyDir(from, to) {
  await mkdir(to, { recursive: true });
  for (const ent of await readdir(from, { withFileTypes: true })) {
    const a = join(from, ent.name);
    const b = join(to, ent.name);
    if (ent.isDirectory()) await copyDir(a, b);
    else await cp(a, b);
  }
}

await copyDir(src, dest);
console.log('Built static PWA into dist/');
