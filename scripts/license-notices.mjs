import fs from 'node:fs';
import path from 'node:path';
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
const notices = ['Relay Shelf third-party notices\n\nThe interface includes shadcn/ui components, distributed under the MIT license.\nhttps://github.com/shadcn-ui/ui/blob/main/LICENSE.md\n'];
if (fs.existsSync('src/components/ui/LICENSE')) notices.push(fs.readFileSync('src/components/ui/LICENSE', 'utf8'));
const seen = new Set();
for (const [directory, entry] of Object.entries(lock.packages)) {
  if (!directory || entry.dev || !fs.existsSync(directory)) continue;
  const metadataPath = path.join(directory, 'package.json');
  if (!fs.existsSync(metadataPath)) continue;
  const metadata = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
  const key = `${metadata.name}@${metadata.version}`;
  if (seen.has(key)) continue;
  seen.add(key);
  const licenses = fs.readdirSync(directory).filter(name => /^(license|licence|copying)(\.|$)/i.test(name));
  notices.push(`\n${'='.repeat(60)}\n${key}\nLicense: ${metadata.license ?? entry.license ?? 'See upstream'}\n`);
  for (const file of licenses) {
    const source = path.join(directory, file);
    if (fs.statSync(source).isFile()) notices.push(fs.readFileSync(source, 'utf8'));
  }
}
fs.writeFileSync(process.argv[2], notices.join('\n'));
