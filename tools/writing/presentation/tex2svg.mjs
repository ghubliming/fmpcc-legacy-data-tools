#!/usr/bin/env node
// Render one TeX formula (stdin) to a self-contained inline SVG (stdout) with MathJax 3 (pinned in
// tools/package.json). Called at build time by deck/filters/mathjax-svg.lua; argv[2] = display|inline.
// Glyphs are drawn as paths inside the SVG, so the formula needs no font, script or network.
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { mathjax } = require('mathjax-full/js/mathjax.js');
const { TeX } = require('mathjax-full/js/input/tex.js');
const { SVG } = require('mathjax-full/js/output/svg.js');
const { liteAdaptor } = require('mathjax-full/js/adaptors/liteAdaptor.js');
const { RegisterHTMLHandler } = require('mathjax-full/js/handlers/html.js');
const { AllPackages } = require('mathjax-full/js/input/tex/AllPackages.js');

const display = process.argv[2] === 'display';
let tex = '';
process.stdin.setEncoding('utf8');
for await (const chunk of process.stdin) tex += chunk;

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
const doc = mathjax.document('', {
  InputJax: new TeX({ packages: AllPackages }),
  OutputJax: new SVG({ fontCache: 'local' }),
});
const out = adaptor.outerHTML(doc.convert(tex.trim(), { display, em: 16, ex: 8, containerWidth: 1280 }));
if (out.includes('data-mjx-error')) {            // never ship a red TeX error box
  process.stderr.write(`TeX error in: ${tex}\n`);
  process.exit(1);
}
process.stdout.write(out);
