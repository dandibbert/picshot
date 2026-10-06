import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../Sources/PicShotFormulaRenderHelper/FormulaRenderResources');
const source=await fs.readFile(path.join(root,'FormulaRenderRuntime.js'),'utf8');
const context=vm.createContext({}, {codeGeneration:{strings:false,wasm:false}});
vm.runInContext(source,context,{timeout:10000});
const render=(latex,options={}) => {
  context.request={latex,fontSize:24,scale:2,transparent:false,...options};
  return JSON.parse(vm.runInContext('FormulaRenderRuntime.render(request)',context,{timeout:10000}));
};

test('locked runtime digest and build size',async()=>{
  assert.equal(createHash('sha256').update(source).digest('hex'),(await fs.readFile(path.join(root,'FormulaRenderRuntime.sha256'),'utf8')).trim());
  assert.ok(Buffer.byteLength(source)<2*1024*1024);
});
for (const [name,latex,semantic] of [
  ['fraction',String.raw`\frac{1}{x^2-1}`,'mfrac'],
  ['superscript','x^{2}+y_{1}','msup'],
  ['matrix',String.raw`\begin{pmatrix}a&b\\c&d\end{pmatrix}`,'mtable'],
  ['radical',String.raw`\sqrt{x+1}`,'msqrt'],
  ['sum',String.raw`\sum_{i=1}^{n}i^2`,'munderover'],
  ['text',String.raw`\text{hello}+\alpha`,'mtext'],
]) {
  test(`${name} renders actual outlines and semantic MathML`,()=>{
    const r=render(latex); assert.equal(r.ok,true,JSON.stringify(r));
    assert.ok(r.mathML.includes(`<${semantic}`));assert.ok(r.svg.includes('<path '));
    assert.ok(r.items.length>0 && r.items.some(i=>i.path?.includes('Q')));
    assert.ok(r.width>32&&r.height>32&&r.width<=4096&&r.height<=4096&&r.width*r.height<=4194304);
    assert.equal(r.width,Math.ceil(r.pointWidth*2)); assert.equal(r.height,Math.ceil(r.pointHeight*2));
    assert.doesNotMatch(r.svg,/<(?:text|script|image|foreignObject|use)\b|\s(?:href|on\w+)=|url\(/i);
    assert.ok(r.items.every(i=>i.matrix.length===6&&i.matrix.every(Number.isFinite)));
  });
}
test('syntax errors do not export a fake/error-text equation',()=>{
  for (const latex of [String.raw`\frac{`,String.raw`\unknowncommand`,String.raw`\begin{matrix}x`]) {
    const r=render(latex); assert.equal(r.ok,false);assert.equal(r.error,'syntax');assert.equal(r.svg,undefined);
  }
});
test('JS runtime has no network, filesystem, DOM or Node bridge',()=>{
  for (const name of ['fetch','XMLHttpRequest','WebSocket','document','window','require','process','setTimeout']) {
    assert.equal(vm.runInContext(`typeof ${name}`,context),'undefined',name);
  }
});
test('resource links, HTML, code injection and custom macros fail closed',()=>{
  for (const latex of [
    String.raw`\href{https://example.com/steal}{x}`,String.raw`\url{https://example.com}`,
    String.raw`\require{html}`,String.raw`\includegraphics{https://example.com/a.png}`,
    String.raw`\style{background:url(https://example.com)}{x}`,String.raw`\htmlClass{evil}{x}`,
    String.raw`\def\a{\a}\a`,String.raw`\newcommand{\a}{1}\a`,String.raw`\unicode{999}`,
  ]) {
    const r=render(latex);assert.equal(r.ok,false,latex);assert.equal(r.svg,undefined);
  }
  const literal=render(`'); globalThis.compromised = true; //`);
  assert.equal(literal.ok,true);assert.doesNotMatch(literal.svg,/<script/i);
  assert.equal(vm.runInContext('typeof compromised',context),'undefined');
});
test('macro expansions, input bytes and dimensions are bounded',()=>{
  for (const latex of ['x'.repeat(8193),'é'.repeat(4097),String.raw`\iff `.repeat(501)+'x']) assert.equal(render(latex).ok,false);
  assert.equal(render('x'.repeat(400),{fontSize:96,scale:3}).ok,false);
  for (const options of [{fontSize:Infinity},{fontSize:11},{fontSize:97},{scale:4},{scale:0}]) assert.equal(render('x',options).ok,false);
});
test('unsupported non-math glyphs are explicit',()=>{const r=render(String.raw`\text{中文}`);assert.equal(r.ok,false);assert.equal(r.error,'unsupportedGlyph');});
test('size and transparency options affect genuine export',()=>{
  const small=render('x^2',{fontSize:24,scale:1,transparent:true});
  const large=render('x^2',{fontSize:48,scale:3,transparent:false});
  assert.equal(small.ok,true);assert.equal(large.ok,true);
  assert.ok(large.width>small.width*3);assert.doesNotMatch(small.svg,/fill="white"/);assert.match(large.svg,/fill="white"/);
});
test('sequential jobs do not inherit TeX definitions or equation state',()=>{
  const before=render('x^2');render(String.raw`\def\x{y}\x`);const after=render('x^2');assert.deepEqual(after,before);
});

test('boxed equations preserve stroke-only rectangles',()=>{
  const r=render(String.raw`\boxed{x}`);assert.equal(r.ok,true);
  const rect=r.items.find(item=>item.kind==='rect');assert.equal(rect.fill,false);assert.ok(rect.strokeWidth>0);
  assert.match(r.svg,/<rect[^>]*fill="none"[^>]*stroke="black"/);
});
test('stretched accents preserve clipped nested SVG viewports',()=>{
  for (const latex of [String.raw`\overline{xy}`,String.raw`\underline{xy}`]) {
    const r=render(latex);assert.equal(r.ok,true);
    assert.ok(r.items.some(item=>item.clips.length>0));
    assert.match(r.svg,/<clipPath id="clip\d+" clipPathUnits="userSpaceOnUse">/);
    assert.doesNotMatch(r.svg,/url\((?!#clip\d+\))/);
  }
});
test('phantoms reserve layout without emitting the invisible glyph',()=>{
  const plain=render('y'),phantom=render(String.raw`\phantom{x}y`);
  assert.equal(phantom.ok,true);assert.ok(phantom.width>plain.width);
  assert.equal(phantom.items.length,plain.items.length);
});
