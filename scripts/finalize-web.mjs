import fs from 'node:fs';
const filename = 'dist/index.html';
const html = fs.readFileSync(filename, 'utf8');
// WKWebView's local file loader supports classic scripts. Vite emits an IIFE.
fs.writeFileSync(filename, html.replace(/ type="module"/g, ' defer').replace(/ crossorigin(?:="[^"]*")?/g, ''));
