// PicShot adapter for the pinned MathJax 3.2.2 source. No browser or Node APIs.
import {mathjax} from 'mathjax-full/js/mathjax.js';
import {TeX} from 'mathjax-full/js/input/tex.js';
import {SVG} from 'mathjax-full/js/output/svg.js';
import {liteAdaptor} from 'mathjax-full/js/adaptors/liteAdaptor.js';
import {RegisterHTMLHandler} from 'mathjax-full/js/handlers/html.js';
import {SerializedMmlVisitor} from 'mathjax-full/js/core/MmlTree/SerializedMmlVisitor.js';
import 'mathjax-full/js/input/tex/base/BaseConfiguration.js';
import 'mathjax-full/js/input/tex/ams/AmsConfiguration.js';

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
const identity = [1, 0, 0, 1, 0, 0];
const limits = {latexBytes:8192, macros:500, buffer:16384, svgBytes:2097152, mathMLBytes:262144,
  items:8192, dimension:4096, pixels:4194304};
function byteLength(s) { return unescape(encodeURIComponent(s)).length; }
function fail(code) { throw new Error(code); }
function finite(n) { return Number.isFinite(n) && Math.abs(n) <= 1000000; }
function multiply(p, m) {
  return [p[0]*m[0]+p[2]*m[1], p[1]*m[0]+p[3]*m[1],
    p[0]*m[2]+p[2]*m[3], p[1]*m[2]+p[3]*m[3],
    p[0]*m[4]+p[2]*m[5]+p[4], p[1]*m[4]+p[3]*m[5]+p[5]];
}
function transform(text = '') {
  let result = identity, cursor = 0;
  const re = /(translate|scale|matrix)\(([^()]*)\)/g;
  let match;
  while ((match = re.exec(text))) {
    if (text.slice(cursor, match.index).trim()) fail('unsafeOutput');
    const values = match[2].trim().split(/[\s,]+/).map(Number);
    if (!values.every(finite)) fail('unsafeOutput');
    let matrix;
    if (match[1] === 'translate' && [1,2].includes(values.length)) matrix=[1,0,0,1,values[0],values[1] || 0];
    else if (match[1] === 'scale' && [1,2].includes(values.length)) matrix=[values[0],0,0,values.length===2 ? values[1] : values[0],0,0];
    else if (match[1] === 'matrix' && values.length===6) matrix=values;
    else fail('unsafeOutput');
    result = multiply(result, matrix); cursor = re.lastIndex;
  }
  if (text.slice(cursor).trim() || !result.every(finite)) fail('unsafeOutput');
  return result;
}
function drawing(svg) {
  const items=[];
  function walk(node, inherited, depth, inheritedFill=true, inheritedStroke=0, clips=[]) {
    if (depth > 128 || items.length >= limits.items || clips.length > 8) fail('limit');
    const kind=adaptor.kind(node);
    if (!['svg','g','path','rect','line'].includes(kind)) fail('unsupportedGlyph');
    const attrs = adaptor.allAttributes(node);
    for (const {name,value} of attrs) {
      if (/^(on|href|xlink:href)/i.test(name) || /url\s*\(/i.test(value)) fail('unsafeOutput');
      // Root vertical alignment has no effect in standalone export. Other styles require explicit support.
      if (name==='style' && !(depth===0 && /^vertical-align:\s*[-.\d]+ex;?$/.test(value))) fail('unsupportedGlyph');
    }
    const number=(name,fallback=0) => { const value=Number(adaptor.getAttribute(node,name) ?? fallback); if (!finite(value)) fail('limit'); return value; };
    let matrix=multiply(inherited,transform(adaptor.getAttribute(node,'transform') || ''));
    if (kind==='svg' && depth>0) {
      const x=number('x'), y=number('y'), width=number('width'), height=number('height');
      const box=(adaptor.getAttribute(node,'viewBox') || '').split(/\s+/).map(Number);
      if (box.length!==4 || !box.every(finite) || width<=0 || height<=0 || box[2]<=0 || box[3]<=0) fail('unsafeOutput');
      const aspect=adaptor.getAttribute(node,'preserveAspectRatio') || 'xMidYMid meet';
      if (aspect!=='xMidYMid meet') fail('unsupportedGlyph');
      // Nested SVG is a clipped viewport (used for stretched accents/bars).
      clips=[...clips,{matrix,x,y,width,height}];
      const scale=Math.min(width/box[2],height/box[3]);
      matrix=multiply(matrix,[scale,0,0,scale,x+(width-box[2]*scale)/2-box[0]*scale,y+(height-box[3]*scale)/2-box[1]*scale]);
    }
    if (!matrix.every(finite)) fail('limit');
    const fillAttribute=adaptor.getAttribute(node,'fill');
    const strokeAttribute=adaptor.getAttribute(node,'stroke');
    if (fillAttribute && !['currentColor','black','none'].includes(fillAttribute)) fail('unsafeOutput');
    if (strokeAttribute && !['currentColor','black','none'].includes(strokeAttribute)) fail('unsafeOutput');
    const fill=fillAttribute ? fillAttribute!=='none' : inheritedFill;
    const strokeWidth=strokeAttribute==='none' ? 0 : number('stroke-width',inheritedStroke);
    if (strokeWidth<0 || strokeWidth>10000) fail('limit');
    if (kind==='path') {
      const path=adaptor.getAttribute(node,'d') || '';
      if (!path || path.length > 100000 || /[^\d\s.,+eE\-MLHVQCSTZmlhvqcstz]/.test(path)) fail('unsupportedGlyph');
      items.push({kind,path,matrix,fill,strokeWidth,clips});
    } else if (kind==='rect' || kind==='line') {
      if (kind==='rect') items.push({kind,matrix,fill,strokeWidth,clips,x:number('x'),y:number('y'),width:number('width'),height:number('height')});
      else items.push({kind,matrix,fill:false,strokeWidth,clips,x:number('x1'),y:number('y1'),width:number('x2'),height:number('y2')});
    }
    for (const child of adaptor.childNodes(node)) walk(child,matrix,depth+1,fill,strokeWidth,clips);
  }
  walk(svg,identity,0);
  if (!items.length) fail('empty');
  return items;
}

export function render(request) {
  try {
    const {latex,fontSize,scale,transparent}=request;
    if (typeof latex!=='string' || !latex.trim() || byteLength(latex)>limits.latexBytes || latex.includes('\0') ||
        !Number.isFinite(fontSize) || fontSize<12 || fontSize>96 || ![1,2,3].includes(scale) || typeof transparent!=='boolean') fail('input');
    // No HTML, URL, resource-loading, persistent macros, links or user code extensions.
    if (/\\(?:href|url|require|autoload|input|include|includegraphics|html\w*|class|style|cssId|bbox|def|gdef|edef|xdef|let|futurelet|newcommand|renewcommand|providecommand|newenvironment|renewenvironment|csname|catcode|unicode|setOptions|label|ref|eqref)\b/.test(latex)) fail('unsafeInput');
    const tex=new TeX({packages:['base','ams'],maxMacros:limits.macros,maxBuffer:limits.buffer,tags:'none',
      formatError:() => fail('syntax')});
    const output=new SVG({fontCache:'none',internalSpeechTitles:false,mtextInheritFont:false});
    const document=mathjax.document('',{InputJax:tex,OutputJax:output});
    const container=document.convert(latex,{display:true,em:fontSize,ex:fontSize/2,containerWidth:100000});
    const svg=adaptor.firstChild(container);
    if (!svg || adaptor.kind(svg)!=='svg') fail('unsafeOutput');
    const viewBox=(adaptor.getAttribute(svg,'viewBox') || '').split(/\s+/).map(Number);
    if (viewBox.length!==4 || !viewBox.every(finite) || viewBox[2]<=0 || viewBox[3]<=0) fail('limit');
    const padding=8, pointWidth=viewBox[2]*fontSize/1000+padding*2, pointHeight=viewBox[3]*fontSize/1000+padding*2;
    const width=Math.ceil(pointWidth*scale),height=Math.ceil(pointHeight*scale);
    if (width>limits.dimension || height>limits.dimension || width*height>limits.pixels) fail('limit');
    const items=drawing(svg);
    // Export one self-contained path-only SVG. No external fonts, CSS, scripts or URLs.
    const pad=padding*1000/fontSize;
    const safeViewBox=[viewBox[0]-pad,viewBox[1]-pad,pointWidth*1000/fontSize,pointHeight*1000/fontSize];
    const definitions=[];
    const shapes=items.map(item => {
      const t=`matrix(${item.matrix.join(' ')})`;
      const paint=`fill="${item.fill?'black':'none'}" stroke="${item.strokeWidth>0?'black':'none'}" stroke-width="${item.strokeWidth}"`;
      let shape;
      if (item.kind==='path') shape=`<path transform="${t}" ${paint} d="${item.path}"/>`;
      else if (item.kind==='rect') shape=`<rect transform="${t}" ${paint} x="${item.x}" y="${item.y}" width="${item.width}" height="${item.height}"/>`;
      else shape=`<line transform="${t}" ${paint} x1="${item.x}" y1="${item.y}" x2="${item.width}" y2="${item.height}"/>`;
      for (const clip of item.clips) {
        const id=`clip${definitions.length}`;
        definitions.push(`<clipPath id="${id}" clipPathUnits="userSpaceOnUse"><rect transform="matrix(${clip.matrix.join(' ')})" x="${clip.x}" y="${clip.y}" width="${clip.width}" height="${clip.height}"/></clipPath>`);
        shape=`<g clip-path="url(#${id})">${shape}</g>`;
      }
      return shape;
    }).join('');
    const background=transparent?'':`<rect x="${safeViewBox[0]}" y="${safeViewBox[1]}" width="${safeViewBox[2]}" height="${safeViewBox[3]}" fill="white"/>`;
    const source=`<svg xmlns="http://www.w3.org/2000/svg" width="${pointWidth}px" height="${pointHeight}px" viewBox="${safeViewBox.join(' ')}" fill="black">${definitions.length?`<defs>${definitions.join('')}</defs>`:''}${background}${shapes}</svg>`;
    const mathML=new SerializedMmlVisitor().visitTree(tex.mathNode);
    if (byteLength(source)>limits.svgBytes || byteLength(mathML)>limits.mathMLBytes || /<(?:script|annotation-xml)|\shref=/i.test(mathML)) fail('limit');
    return JSON.stringify({ok:true,svg:source,mathML,items,viewBox,fontSize,padding,width,height,pointWidth,pointHeight});
  } catch (error) {
    const known=['input','unsafeInput','syntax','unsupportedGlyph','unsafeOutput','limit','empty'];
    return JSON.stringify({ok:false,error:known.includes(error.message)?error.message:'syntax'});
  }
}
