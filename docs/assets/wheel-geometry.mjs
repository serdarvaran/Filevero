// Browser port of Sources/FileveroApp/WheelSpatialGeometry.swift and the label
// fitting in WheelSegmentLayout.swift. Native coordinates are flipped into SVG's
// downward Y axis; keep the native proportions and rounded petals.
export const SIZE = 320, RADIUS = SIZE * .44, INNER = RADIUS * .407, DISC = INNER - 4;
export const MAX_LABEL_WIDTH = 84, ICON = 20, ICON_SPACING = 4, LABEL_PADDING = 3.5, CENTER_FONT = 11;
const rad = degrees => degrees * Math.PI / 180;
const native = (radius, degrees) => ({x: 160 + radius * Math.cos(rad(degrees)), y: 160 + radius * Math.sin(rad(degrees))});
export const angle = (count, index) => (count === 3 ? 180 : 90) - index * 360 / count;
const xy = p => `${p.x.toFixed(4)},${(SIZE - p.y).toFixed(4)}`;
// NSBezierPath.appendArc: a line to the arc start, then cubic segments of at most 90°.
function arc(radius, start, end) {
  const parts = [`L${xy(native(radius, start))}`], direction = Math.sign(end - start);
  for (let from = start; Math.abs(end - from) > 1e-9;) {
    const to = Math.abs(end - from) > 90 ? from + 90 * direction : end, k = 4 / 3 * Math.tan(rad(to - from) / 4);
    const p0 = native(radius, from), p3 = native(radius, to), s0 = Math.sin(rad(from)), c0 = Math.cos(rad(from)), s3 = Math.sin(rad(to)), c3 = Math.cos(rad(to));
    parts.push(`C${xy({x: p0.x - k * radius * s0, y: p0.y + k * radius * c0})} ${xy({x: p3.x + k * radius * s3, y: p3.y - k * radius * c3})} ${xy(p3)}`);
    from = to;
  }
  return parts.join(' ');
}
const corner = (to, control) => `C${xy(control)} ${xy(control)} ${xy(to)}`;
export function petal(count, index) {
  const delta = 360 / count, mid = angle(count, index), a = mid - delta / 2 + .9, b = mid + delta / 2 - .9;
  const round = Math.min(10, INNER * rad(delta) / 4), oi = round / RADIUS * 180 / Math.PI, ii = round / INNER * 180 / Math.PI;
  return [
    `M${xy(native(RADIUS - round, a))}`, corner(native(RADIUS, a + oi), native(RADIUS, a)), arc(RADIUS, a + oi, b - oi),
    corner(native(RADIUS - round, b), native(RADIUS, b)), `L${xy(native(INNER + round, b))}`, corner(native(INNER, b - ii), native(INNER, b)),
    arc(INNER, b - ii, a + ii), corner(native(INNER + round, a), native(INNER, a)), 'Z',
  ].join(' ');
}
// Area centroid of the annular sector first, then nearby radial and tangential fallbacks.
export function labelCenters(count, index) {
  const sweep = rad(360 / count - 1.8), centroid = count > 1 ? 4 * Math.sin(sweep / 2) * (RADIUS ** 3 - INNER ** 3) / (3 * sweep * (RADIUS ** 2 - INNER ** 2)) : (RADIUS + INNER) / 2;
  const preferred = centroid / RADIUS, fractions = [preferred];
  for (let step = 1; step <= 12; step++) fractions.push(preferred + step * .02, preferred - step * .02);
  const valid = fractions.filter(f => f > INNER / RADIUS && f < .86).concat([.73, .75, .71, .77, .69, .79, .67, .81]);
  const theta = rad(angle(count, index));
  return valid.flatMap(f => [0, -4, 4, -8, 8].map(t => ({x: 160 + RADIUS * f * Math.cos(theta) - t * Math.sin(theta), y: 160 - RADIUS * f * Math.sin(theta) - t * Math.cos(theta)})));
}
// Native wrapping keeps an over-long word on its own line; the fit check rejects it.
function wrap(text, width, font, measure) {
  const lines = [];
  for (const paragraph of text.split('\n')) {
    let line = '';
    for (const word of paragraph.split(' ').filter(Boolean)) {
      const next = line ? line + ' ' + word : word;
      if (line && measure(next, font).width > width) { lines.push(line); line = word; } else line = next;
    }
    lines.push(line);
  }
  return lines;
}
export function containsRect(rect, contains, padding = LABEL_PADDING) {
  const x = rect.x - padding, y = rect.y - padding, w = rect.width + 2 * padding, h = rect.height + 2 * padding;
  for (let i = 0; i <= 8; i++) { const t = i / 8; if (!contains(x + w * t, y) || !contains(x + w * t, y + h) || !contains(x, y + h * t) || !contains(x + w, y + h * t)) return false; }
  return true;
}
function block(title, width, font, hasIcon, center, measure) {
  const lines = wrap(title, width, font, measure), metrics = lines.map(line => measure(line, font)), lineHeight = font * 1.18;
  const iconBlock = hasIcon ? ICON + ICON_SPACING : 0, height = lines.length * lineHeight + iconBlock, top = center.y - height / 2, rects = [];
  if (hasIcon) rects.push({x: center.x - ICON / 2, y: top, width: ICON, height: ICON});
  metrics.forEach((m, j) => rects.push({x: center.x - m.width / 2, y: top + iconBlock + j * lineHeight, width: m.width, height: lineHeight}));
  return {...center, font, lineHeight, height, lines, rects, width: Math.max(hasIcon ? ICON : 0, ...metrics.map(m => m.width))};
}
// Port of WheelSegmentLayout.fitted: shrink the font up to 3 points, narrow the
// text block and try every candidate center until the icon and lines fit the petal.
export function fitLabel(count, index, title, hasIcon, measure, contains) {
  const centers = labelCenters(count, index), maximumWidth = MAX_LABEL_WIDTH, baseFont = hasIcon ? 9.5 : 13;
  for (let reduction = 0; reduction <= 3; reduction += .25) {
    const font = Math.max(6, baseFont - reduction);
    let best, bestScore = Infinity;
    for (let width = maximumWidth; width >= 36; width -= 4) {
      for (let ci = 0; ci < centers.length; ci++) {
        const placed = block(title, width, font, hasIcon, centers[ci], measure);
        if (!placed.rects.every(r => containsRect(r, contains))) continue;
        if (width === maximumWidth && ci === 0) return {...placed, fits: true};
        const score = placed.lines.length * 10 + ci + (maximumWidth - width) / maximumWidth;
        if (score < bestScore) { best = placed; bestScore = score; }
      }
    }
    if (best) return {...best, fits: true};
  }
  // Never silently truncate a new catalog title; browser checks flag this.
  return {...block(title, maximumWidth, baseFont, hasIcon, centers[0], measure), fits: false};
}
// Like WheelView.layoutLabels: when any label in a wheel of icon items is clipped,
// every petal shows only its icon and the centre disc names the hovered option.
export function fitLabels(count, entries, measure, containsFor) {
  const layouts = entries.map(({title, hasIcon}, index) => fitLabel(count, index, title, hasIcon, measure, containsFor(index)));
  if (layouts.every(layout => layout.fits) || !entries.every(entry => entry.hasIcon)) return layouts;
  return layouts.map((layout, index) => {
    const icons = labelCenters(count, index).map(center => ({center, icon: {x: center.x - ICON / 2, y: center.y - ICON / 2, width: ICON, height: ICON}}));
    const placed = icons.find(({icon}) => containsRect(icon, containsFor(index)));
    const {center, icon} = placed || icons[0];
    return {...center, font: layout.font, lineHeight: layout.lineHeight, height: ICON, width: ICON, lines: [], rects: [icon], fits: !!placed, iconOnly: true};
  });
}
