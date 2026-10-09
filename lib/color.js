ObjC.import('AppKit');
ObjC.import('CoreImage');
ObjC.import('stdlib');

const SAMPLE_SIZE = 32;
const CALIBRATION_STEPS = 14;
const HUE_TOLERANCE_DEGREES = 1;
const SATURATION_TOLERANCE = 0.02;
const HUE_WEIGHT_DEGREES = 30;
const CALIBRATION_DAMPING = 0.5;
const HUE_BINS = 36;
const MIN_SATURATION = 0.2;
const MIN_VALUE = 0.2;
const MIN_ALPHA = 0.5;
const PEAK_WINDOW_DEGREES = 20;
const MAX_SATURATION_SCALE = 2;

function fail(message) {
  const data = $(message + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardError.writeData(data);
  $.exit(1);
}

function clamp(value, low, high) {
  return Math.min(high, Math.max(low, value));
}

function wrapDegrees(value) {
  return ((value % 360) + 360) % 360;
}

function signedDelta(value) {
  const wrapped = wrapDegrees(value);
  return wrapped > 180 ? wrapped - 360 : wrapped;
}

function parseHex(hex) {
  const match = /^#?([0-9a-fA-F]{6})$/.exec(hex || '');
  if (!match) fail('color.js: invalid color "' + hex + '" (expected #rrggbb)');
  const n = parseInt(match[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((c) => c / 255);
}

function toHex(rgb) {
  return '#' + rgb.map((c) => Math.round(clamp(c, 0, 1) * 255).toString(16).padStart(2, '0')).join('');
}

function rgbToHsv(rgb) {
  const [r, g, b] = rgb;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const delta = max - min;
  let hue = 0;
  if (delta > 0) {
    if (max === r) hue = 60 * (((g - b) / delta) % 6);
    else if (max === g) hue = 60 * ((b - r) / delta + 2);
    else hue = 60 * ((r - g) / delta + 4);
  }
  return [wrapDegrees(hue), max === 0 ? 0 : delta / max, max];
}

function hsvToRgb(hsv) {
  const [h, s, v] = hsv;
  const chroma = v * s;
  const x = chroma * (1 - Math.abs(((wrapDegrees(h) / 60) % 2) - 1));
  const m = v - chroma;
  const sector = Math.floor(wrapDegrees(h) / 60);
  const table = [[chroma, x, 0], [x, chroma, 0], [0, chroma, x], [0, x, chroma], [x, 0, chroma], [chroma, 0, x]];
  return table[sector % 6].map((c) => c + m);
}

function colorComponents(color) {
  const rgb = color.colorUsingColorSpace($.NSColorSpace.sRGBColorSpace);
  return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent];
}

function dominantOf(allPixels) {
  const pixels = allPixels.filter(([, s, v]) => s >= MIN_SATURATION && v >= MIN_VALUE);
  if (pixels.length === 0) return [0, 0, 1];
  const bins = new Array(HUE_BINS).fill(0);
  const binWidth = 360 / HUE_BINS;
  pixels.forEach(([h, s, v]) => { bins[Math.floor(h / binWidth) % HUE_BINS] += s * v; });
  const peak = bins.indexOf(Math.max(...bins));
  const center = (peak + 0.5) * binWidth;
  let sumX = 0, sumY = 0, sumWeight = 0, sumS = 0, sumV = 0;
  pixels.forEach(([h, s, v]) => {
    if (Math.abs(signedDelta(h - center)) > PEAK_WINDOW_DEGREES) return;
    const weight = s * v;
    sumX += Math.cos(h * Math.PI / 180) * weight;
    sumY += Math.sin(h * Math.PI / 180) * weight;
    sumS += s * weight;
    sumV += v * weight;
    sumWeight += weight;
  });
  return [wrapDegrees(Math.atan2(sumY, sumX) * 180 / Math.PI), sumS / sumWeight, sumV / sumWeight];
}

function loadScaled(path) {
  const image = $.CIImage.imageWithContentsOfURL($.NSURL.fileURLWithPath(path));
  if (!image || image.isNil()) fail('color.js: cannot read image ' + path);
  const width = image.extent.size.width;
  if (!(width > 0)) fail('color.js: empty image ' + path);
  const scale = $.CIFilter.filterWithName('CILanczosScaleTransform');
  scale.setValueForKey(image, 'inputImage');
  scale.setValueForKey($(SAMPLE_SIZE / width), 'inputScale');
  scale.setValueForKey($(1), 'inputAspectRatio');
  return scale.valueForKey('outputImage');
}

function applyTint(image, angleDegrees, saturation) {
  const hue = $.CIFilter.filterWithName('CIHueAdjust');
  hue.setValueForKey(image, 'inputImage');
  hue.setValueForKey($(angleDegrees * Math.PI / 180), 'inputAngle');
  const controls = $.CIFilter.filterWithName('CIColorControls');
  controls.setValueForKey(hue.valueForKey('outputImage'), 'inputImage');
  controls.setValueForKey($(saturation), 'inputSaturation');
  return controls.valueForKey('outputImage');
}

function pixelsOf(image) {
  const rep = $.NSBitmapImageRep.alloc.initWithCIImage(image);
  const width = rep.pixelsWide;
  const height = rep.pixelsHigh;
  const pixels = [];
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const [r, g, b, a] = colorComponents(rep.colorAtXY(x, y));
      if (a >= MIN_ALPHA) pixels.push(rgbToHsv([r, g, b].map((c) => clamp(c, 0, 1))));
    }
  }
  return pixels;
}

function measure(image, angleDegrees, saturation) {
  return dominantOf(pixelsOf(applyTint(image, angleDegrees, saturation)));
}

function dominant(path) {
  return dominantOf(pixelsOf(loadScaled(path)));
}

function calibrate(image, sourceHue, targetHue, targetSat) {
  let angle = signedDelta(targetHue - sourceHue);
  let saturation = 1;
  let best = [angle, saturation];
  let bestScore = Infinity;
  for (let step = 0; step < CALIBRATION_STEPS; step++) {
    const [hue, sat] = measure(image, angle, saturation);
    const hueError = signedDelta(targetHue - hue);
    const satError = targetSat === null ? 0 : targetSat - sat;
    const score = Math.abs(hueError) / HUE_WEIGHT_DEGREES + Math.abs(satError);
    if (score < bestScore) { bestScore = score; best = [angle, saturation]; }
    if (Math.abs(hueError) < HUE_TOLERANCE_DEGREES && Math.abs(satError) < SATURATION_TOLERANCE) break;
    angle = signedDelta(angle + CALIBRATION_DAMPING * hueError);
    if (targetSat !== null && sat > 0.01) {
      saturation = clamp(saturation * (1 + CALIBRATION_DAMPING * (targetSat / sat - 1)), 0, MAX_SATURATION_SCALE);
    }
  }
  return best;
}

function params(target, imagePath) {
  const image = loadScaled(imagePath);
  const [sourceHue, sourceSat, sourceValue] = dominantOf(pixelsOf(image));
  let targetHue;
  let targetSat = null;
  let colorHex;
  if (/^#?[0-9a-fA-F]{6}$/.test(target)) {
    const hsv = rgbToHsv(parseHex(target));
    targetHue = hsv[0];
    targetSat = hsv[1];
    colorHex = toHex(parseHex(target));
  } else {
    targetHue = parseFloat(target);
    if (!isFinite(targetHue)) fail('color.js: target must be #rrggbb or a hue in degrees');
    targetHue = wrapDegrees(targetHue);
    colorHex = toHex(hsvToRgb([targetHue, sourceSat, sourceValue]));
  }
  if (sourceSat < 0.05) return [0, targetSat === null ? 1 : targetSat, colorHex];
  const [angle, saturation] = calibrate(image, sourceHue, targetHue, targetSat);
  return [angle, saturation, colorHex];
}

function pick(defaultHex) {
  const app = Application.currentApplication();
  app.includeStandardAdditions = true;
  const start = parseHex(defaultHex || '#3a7bd5').map((c) => Math.round(c * 65535));
  let chosen;
  try {
    chosen = app.chooseColor({ defaultColor: start });
  } catch (error) {
    fail('color.js: color selection cancelled');
  }
  return toHex(chosen.map((c) => c / 65535));
}

function formatHsv(hsv) {
  return hsv[0].toFixed(1) + ' ' + hsv[1].toFixed(3) + ' ' + hsv[2].toFixed(3);
}

function run(argv) {
  const command = argv[0];
  switch (command) {
    case 'pick':
      return pick(argv[1]);
    case 'dominant':
      if (!argv[1]) fail('usage: color.js dominant <image>');
      return formatHsv(dominant(argv[1]));
    case 'dominant-hex':
      if (!argv[1]) fail('usage: color.js dominant-hex <image>');
      return toHex(hsvToRgb(dominant(argv[1])));
    case 'hsv':
      return formatHsv(rgbToHsv(parseHex(argv[1])));
    case 'hex':
      return toHex(hsvToRgb([parseFloat(argv[1]), parseFloat(argv[2]), parseFloat(argv[3])]));
    case 'params': {
      if (!argv[1] || !argv[2]) fail('usage: color.js params <#rrggbb|hue-degrees> <source-image>');
      const [angle, saturation, hex] = params(argv[1], argv[2]);
      return angle.toFixed(1) + ' ' + saturation.toFixed(3) + ' ' + hex;
    }
    default:
      fail('usage: color.js pick [#default] | dominant <image> | dominant-hex <image> | hsv <#hex> | hex <h> <s> <v> | params <#hex|hue> <image>');
  }
}
