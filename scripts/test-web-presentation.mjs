#!/usr/bin/env node
// Check the browser port against the actual native geometry, without running
// either UI or changing user preferences. swiftc is optional off macOS.
import assert from 'node:assert/strict';
import {readFileSync,mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {SIZE,RADIUS,INNER,DISC,MAX_LABEL_WIDTH,ICON,ICON_SPACING,LABEL_PADDING,CENTER_FONT,angle,petal,labelCenters,containsRect,fitLabel,fitLabels} from '../docs/assets/wheel-geometry.mjs';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const catalog=JSON.parse(readFileSync(join(root,'docs/assets/demo/catalog.json')));
assert.deepEqual(catalog.presentation.feedback,{voices:3,volume:.65,minimumInterval:.05});
assert.equal(SIZE,320);assert.equal(angle(3,0),180);
assert.equal(Object.keys(catalog.presentation.wheelTitles).length,29);
assert.equal(Object.keys(catalog.presentation.editorTitles).length,43);
for(const title of Object.values(catalog.presentation.wheelTitles))assert.ok(catalog.presentation.translations[title],`Missing native Turkish title: ${title}`);
assert.equal(catalog.presentation.palette.Paper.dark,'#161721');
assert.deepEqual(readFileSync(join(root,'Resources/Sounds/WheelSelection.wav')),readFileSync(join(root,'docs/assets/demo/wheel-selection.wav')));
// Parse an SVG path written by petal() into AppKit-style elements: [kind, points].
const KINDS={M:0,L:1,C:2,Z:3};
const elements=d=>[...d.matchAll(/([MLCZ])([^MLCZ]*)/g)].map(([,k,args])=>[KINDS[k],(args.trim().match(/-?[\d.]+,-?[\d.]+/g)||[]).map(p=>p.split(',').map(Number))]);
// Annular-sector containment (ignores the small rounded corners), SVG coordinates.
const inSector=(count,index)=>(x,y)=>{
 const r=Math.hypot(x-160,160-y),delta=360/count,a=angle(count,index)-delta/2+.9;
 const t=((Math.atan2(160-y,x-160)*180/Math.PI-a)%360+360)%360;
 return r>=INNER&&r<=RADIUS&&t<=delta-1.8;
};
const measure=(text,font)=>({width:text.length*font*.6});
for(let count=1;count<=9;count++)for(let index=0;index<count;index++){
 const d=petal(count,index);
 assert.ok(!/NaN|Infinity/.test(d));
 assert.match(d.replace(/[^MLCZ]/g,''),/^MCLCC+LCLCC+Z$/,'Every petal keeps four rounded corners around its two arcs');
 const c=labelCenters(count,index)[0],r=Math.hypot(c.x-160,c.y-160);assert.ok(r>INNER&&r<RADIUS,'Preferred label center lies inside the petal');
 const label=fitLabel(count,index,'Convert',true,measure,inSector(count,index));
 assert.ok(label.fits&&label.rects.every(rect=>containsRect(rect,inSector(count,index))),`A short label fits petal ${count}/${index}`);
}
assert.equal(fitLabel(9,0,'W'.repeat(40),false,measure,inSector(9,0)).fits,false,'Over-long labels are flagged, not truncated');
const dense=n=>Array.from({length:9},(_,i)=>({title:i===0?'W'.repeat(n):'Ok',hasIcon:true}));
assert.ok(fitLabels(9,dense(2),measure,i=>inSector(9,i)).every(l=>!l.iconOnly&&l.lines.length),'Wheels whose labels fit keep them');
assert.ok(fitLabels(9,dense(40),measure,i=>inSector(9,i)).every((l,i)=>l.iconOnly&&l.fits&&!l.lines.length&&containsRect(l.rects[0],inSector(9,i))),'A clipped icon wheel shows icons only');
assert.ok(fitLabels(9,dense(40).map(e=>({...e,hasIcon:false})),measure,i=>inSector(9,i)).some(l=>!l.fits),'Text-only wheels are flagged, never hidden');
assert.equal(containsRect({x:1,y:1,width:2,height:2},(x,y)=>x>=0&&y>=0&&x<=4&&y<=4,0),true);
assert.equal(containsRect({x:1,y:1,width:2,height:2},(x,y)=>x>=0&&y>=0&&x<=4&&y<=4),false,'Padding must protect labels from edges');
// WheelView is not standalone-compilable, so pin the drawing constants the
// browser port mirrors; a native change must update wheel-geometry.mjs too.
const wheelSource=readFileSync(join(root,'Sources/FileveroApp/SpatialSelectionWheel.swift'),'utf8');
for(const [snippet,why] of [
 ['public func petal(_ index: Int) -> NSBezierPath { geometry.petal(index) }','petal source (drawing and hit-testing)'],
 ['NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))','round backdrop'],
 ['centers: geometry.labelCenters(i)','label centers'],
 [`maximumWidth: ${MAX_LABEL_WIDTH} * scale`,'label width'],
 [`iconSize: source == nil ? nil : ${ICON} * scale`,'icon size'],
 ['ofSize: (source == nil ? 13 : 9.5) * scale','label font'],
 [`padding: ${LABEL_PADDING} * geometry.scale`,'label audit padding'],
 [`ofSize: ${CENTER_FONT} * scale`,'centre font'],
 ['inside: disc,','centre disc label'],
 ['let iconOnly = clipped && fitted.allSatisfy { $0.iconRect != nil }','icon-only rule for dense wheels'],
])assert.ok(wheelSource.includes(snippet),`SpatialSelectionWheel.swift changed its ${why}; update docs/assets/wheel-geometry.mjs`);
const layoutSource=readFileSync(join(root,'Sources/FileveroApp/WheelSegmentLayout.swift'),'utf8');
assert.ok(layoutSource.includes(`spacing: ${ICON_SPACING} * scale`),'WheelSegmentLayout icon spacing changed');
assert.ok(layoutSource.includes(`padding: ${LABEL_PADDING} * scale`),'WheelSegmentLayout fit padding changed');
if(process.platform==='darwin'){
 const dir=mkdtempSync(join(tmpdir(),'filevero-web-geometry-'));
 try{
  const harness=join(dir,'main.swift'),binary=join(dir,'geometry');
  // Compile the real WheelSpatialGeometry.swift, unchanged, with a tiny dumper.
  writeFileSync(harness,`import AppKit
var rows:[[String:Any]]=[]
for count in 1...9 { for index in 0..<count {
 let g=WheelSpatialGeometry(bounds:NSRect(x:0,y:0,width:${SIZE},height:${SIZE}),count:count)
 let path=g.petal(index)
 var elements:[[Any]]=[]
 var pts=[NSPoint](repeating:.zero,count:3)
 for i in 0..<path.elementCount {
  let kind=path.element(at:i,associatedPoints:&pts)
  let n=kind == .cubicCurveTo ? 3 : kind == .closePath ? 0 : 1
  elements.append([Int(kind.rawValue),pts.prefix(n).map { [Double($0.x),Double(${SIZE}-$0.y)] }])
 }
 rows.append(["count":count,"index":index,"radius":Double(g.radius),"inner":Double(g.inner),"disc":Double(g.disc.bounds.width/2),
  "centers":g.labelCenters(index).map { [Double($0.x),Double(${SIZE}-$0.y)] },"elements":elements])
}}
let data=try JSONSerialization.data(withJSONObject:rows)
print(String(data:data,encoding:.utf8)!)
`);
  const build=spawnSync('swiftc',[join(root,'Sources/FileveroApp/WheelSpatialGeometry.swift'),harness,'-o',binary],{encoding:'utf8'});assert.equal(build.status,0,build.stderr);
  const run=spawnSync(binary,[],{encoding:'utf8'});assert.equal(run.status,0,run.stderr);
  const oracle=JSON.parse(run.stdout);let points=0;
  for(const row of oracle){
   const at=`${row.count}/${row.index}`;
   assert.ok(Math.abs(row.radius-RADIUS)<1e-9&&Math.abs(row.inner-INNER)<1e-9&&Math.abs(row.disc-DISC)<1e-9,`Radii, ${at}`);
   const centers=labelCenters(row.count,row.index);assert.equal(centers.length,row.centers.length,`Label candidates, ${at}`);
   centers.forEach((c,i)=>assert.ok(Math.abs(c.x-row.centers[i][0])<1e-8&&Math.abs(c.y-row.centers[i][1])<1e-8,`Label candidate ${i}, ${at}`));
   // AppKit appends a trailing moveTo after closePath; it draws nothing.
   const native=row.elements.at(-1)[0]===0?row.elements.slice(0,-1):row.elements,browser=elements(petal(row.count,row.index));
   assert.equal(browser.length,native.length,`Element count, ${at}`);
   native.forEach(([kind,pts],i)=>{
    assert.equal(browser[i][0],kind,`Element kind ${i}, ${at}`);
    assert.equal(browser[i][1].length,pts.length);
    pts.forEach((p,j)=>{points++;assert.ok(Math.abs(browser[i][1][j][0]-p[0])<1e-3&&Math.abs(browser[i][1][j][1]-p[1])<1e-3,`Point ${i}.${j}, ${at}: ${browser[i][1][j]} vs ${p}`);});
   });
  }
  console.log(`Native Swift/browser wheel geometry agrees for ${oracle.length} petals (${points} path points) and every label candidate.`);
 }finally{rmSync(dir,{recursive:true,force:true});}
}
console.log('Native catalog, Turkish labels, palette, rounded petals, label fitting and sound asset checks passed.');
