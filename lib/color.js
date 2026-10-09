ObjC.import('AppKit');
ObjC.import('CoreImage');
ObjC.import('stdlib');

const SAMPLE_SIZE = 128;
const HUE_BINS = 36;
const MIN_SATURATION = 0.2;
const MIN_VALUE = 0.2;
const MIN_ALPHA = 0.5;
const PEAK_WINDOW_DEGREES = 20;
const BMP_DATA_OFFSET = 10;
const BMP_WIDTH_OFFSET = 18;
const BMP_HEIGHT_OFFSET = 22;
const CUBE_DIMENSION = 64;
const WEIGHT_LOW = 0.06;
const WEIGHT_HIGH = 0.22;
const MIN_SOURCE_SATURATION = 0.05;
const MIN_HUE_SATURATION = 0.02;
const CALIBRATION_STEPS = 12;
const MIN_SCALE_GROWTH = 1.3;
const CALIBRATION_CUBE_DIMENSION = 33;
const CALIBRATION_TOLERANCE = 0.003;
const MAX_SCALE = 8;
const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const BASE64_CHUNK = 8192;

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
  const sector = wrapDegrees(h) / 60;
  const channel = (offset) => {
    const k = (offset + sector) % 6;
    return v - v * s * Math.max(0, Math.min(k, 4 - k, 1));
  };
  return [channel(5), channel(3), channel(1)];
}

function smoothstep(low, high, value) {
  const t = clamp((value - low) / (high - low), 0, 1);
  return t * t * (3 - 2 * t);
}

function dominanceWeight(hsv) {
  return hsv[1] * hsv[2];
}

function dominantIndices(pixels) {
  const indices = [];
  pixels.forEach((pixel, index) => {
    if (pixel && pixel[1] >= MIN_SATURATION && pixel[2] >= MIN_VALUE) indices.push(index);
  });
  if (indices.length === 0) return [];
  const bins = new Array(HUE_BINS).fill(0);
  const binWidth = 360 / HUE_BINS;
  indices.forEach((index) => {
    const h = pixels[index][0];
    bins[Math.floor(h / binWidth) % HUE_BINS] += dominanceWeight(pixels[index]);
  });
  const center = (bins.indexOf(Math.max(...bins)) + 0.5) * binWidth;
  return indices.filter((index) => Math.abs(signedDelta(pixels[index][0] - center)) <= PEAK_WINDOW_DEGREES);
}

function weightedMean(entries) {
  let sumX = 0, sumY = 0, sumWeight = 0, sumS = 0, sumV = 0;
  entries.forEach(([weight, [h, s, v]]) => {
    sumX += Math.cos(h * Math.PI / 180) * weight;
    sumY += Math.sin(h * Math.PI / 180) * weight;
    sumS += s * weight;
    sumV += v * weight;
    sumWeight += weight;
  });
  return [wrapDegrees(Math.atan2(sumY, sumX) * 180 / Math.PI), sumS / sumWeight, sumV / sumWeight];
}

function dominantOf(pixels) {
  const selected = dominantIndices(pixels);
  if (selected.length === 0) return [0, 0, 1];
  return weightedMean(selected.map((index) => [dominanceWeight(pixels[index]), pixels[index]]));
}

function loadImage(path) {
  const image = $.CIImage.imageWithContentsOfURL($.NSURL.fileURLWithPath(path));
  if (!image || image.isNil()) fail('color.js: cannot read image ' + path);
  if (!(image.extent.size.width > 0)) fail('color.js: empty image ' + path);
  return image;
}

function applyFilter(name, image, values) {
  const filter = $.CIFilter.filterWithName(name);
  filter.setValueForKey(image, 'inputImage');
  Object.keys(values || {}).forEach((key) => filter.setValueForKey(values[key], key));
  return filter.valueForKey('outputImage');
}

function scaled(image) {
  return applyFilter('CILanczosScaleTransform', image, {
    inputScale: $(SAMPLE_SIZE / image.extent.size.width),
    inputAspectRatio: $(1),
  });
}

function decodeBase64(text) {
  const lookup = {};
  for (let i = 0; i < BASE64_ALPHABET.length; i++) lookup[BASE64_ALPHABET[i]] = i;
  const clean = text.replace(/=+$/, '');
  const bytes = new Uint8Array(Math.floor(clean.length * 3 / 4));
  let written = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const n = (lookup[clean[i]] << 18) | (lookup[clean[i + 1]] << 12) | ((lookup[clean[i + 2]] || 0) << 6) | (lookup[clean[i + 3]] || 0);
    for (let shift = 16; shift >= 0 && written < bytes.length; shift -= 8) bytes[written++] = (n >> shift) & 255;
  }
  return bytes;
}

function pixelsOf(image) {
  const rep = $.NSBitmapImageRep.alloc.initWithCIImage(image);
  const bmp = rep.representationUsingTypeProperties($.NSBitmapImageFileTypeBMP, $());
  const bytes = decodeBase64(ObjC.unwrap(bmp.base64EncodedStringWithOptions(0)));
  const view = new DataView(bytes.buffer);
  const dataOffset = view.getUint32(BMP_DATA_OFFSET, true);
  const width = view.getInt32(BMP_WIDTH_OFFSET, true);
  const height = Math.abs(view.getInt32(BMP_HEIGHT_OFFSET, true));
  const topDown = view.getInt32(BMP_HEIGHT_OFFSET, true) < 0;
  const pixels = new Array(width * height);
  for (let row = 0; row < height; row++) {
    for (let x = 0; x < width; x++) {
      const at = dataOffset + (((topDown ? row : height - 1 - row) * width) + x) * 4;
      pixels[row * width + x] = bytes[at + 3] / 255 >= MIN_ALPHA
        ? rgbToHsv([bytes[at + 2] / 255, bytes[at + 1] / 255, bytes[at] / 255])
        : null;
    }
  }
  return pixels;
}

function dominant(path) {
  return dominantOf(pixelsOf(scaled(loadImage(path))));
}

function hueChannel(offset, sector) {
  const k = (offset + sector) % 6;
  return Math.max(0, Math.min(k, 4 - k, 1));
}

function mapInto(target, offset, r, g, b, tint) {
  const max = Math.max(r, g, b);
  const delta = max - Math.min(r, g, b);
  const saturation = max === 0 ? 0 : delta / max;
  const weight = smoothstep(WEIGHT_LOW, WEIGHT_HIGH, saturation);
  if (weight === 0) {
    target[offset] = r;
    target[offset + 1] = g;
    target[offset + 2] = b;
    return;
  }
  let hue = 0;
  if (delta > 0) {
    if (max === r) hue = 60 * (((g - b) / delta) % 6);
    else if (max === g) hue = 60 * ((b - r) / delta + 2);
    else hue = 60 * ((r - g) / delta + 4);
  }
  const sector = wrapDegrees(hue + tint.hueShift) / 60;
  const mappedSat = clamp(saturation * tint.satScale, 0, 1);
  const mappedValue = clamp(max * tint.valueScale, 0, 1);
  const chroma = mappedValue * mappedSat;
  target[offset] = clamp(r + (mappedValue - chroma * hueChannel(5, sector) - r) * weight, 0, 1);
  target[offset + 1] = clamp(g + (mappedValue - chroma * hueChannel(3, sector) - g) * weight, 0, 1);
  target[offset + 2] = clamp(b + (mappedValue - chroma * hueChannel(1, sector) - b) * weight, 0, 1);
}

function base64Of(bytes) {
  const codes = new Uint16Array(Math.ceil(bytes.length / 3) * 4);
  const alphabet = Array.from(BASE64_ALPHABET, (c) => c.charCodeAt(0));
  let written = 0;
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0);
    codes[written++] = alphabet[(n >> 18) & 63];
    codes[written++] = alphabet[(n >> 12) & 63];
    codes[written++] = i + 1 < bytes.length ? alphabet[(n >> 6) & 63] : 61;
    codes[written++] = i + 2 < bytes.length ? alphabet[n & 63] : 61;
  }
  const parts = [];
  for (let start = 0; start < codes.length; start += BASE64_CHUNK) {
    parts.push(String.fromCharCode.apply(null, codes.subarray(start, start + BASE64_CHUNK)));
  }
  return parts.join('');
}

function colorCube(tint, dimension) {
  const floats = new Float32Array(dimension * dimension * dimension * 4);
  const last = dimension - 1;
  let offset = 0;
  for (let b = 0; b < dimension; b++) {
    for (let g = 0; g < dimension; g++) {
      for (let r = 0; r < dimension; r++) {
        mapInto(floats, offset, r / last, g / last, b / last, tint);
        floats[offset + 3] = 1;
        offset += 4;
      }
    }
  }
  const data = $.NSData.alloc.initWithBase64EncodedStringOptions($(base64Of(new Uint8Array(floats.buffer))), 0);
  if (!data || data.isNil()) fail('color.js: cannot build the color cube');
  return { data, dimension };
}

function applyCube(image, cube) {
  const encoded = applyFilter('CILinearToSRGBToneCurve', image);
  const mapped = applyFilter('CIColorCube', encoded, { inputCubeDimension: $(cube.dimension), inputCubeData: cube.data });
  return applyFilter('CISRGBToneCurveToLinear', mapped);
}

function calibrate(image, target) {
  const [targetHue, targetSat, targetValue] = target;
  const sourcePixels = pixelsOf(scaled(image));
  const selected = dominantIndices(sourcePixels);
  const entriesFor = (pixels) => selected
    .filter((index) => pixels[index])
    .map((index) => [dominanceWeight(sourcePixels[index]), pixels[index]]);
  const [sourceHue, sourceSat, sourceValue] = selected.length === 0 ? [0, 0, 1] : weightedMean(entriesFor(sourcePixels));
  const tint = { hueShift: 0, satScale: 1, valueScale: sourceValue > 0 ? targetValue / sourceValue : 1 };
  if (sourceSat < MIN_SOURCE_SATURATION) return tint;
  tint.hueShift = signedDelta(targetHue - sourceHue);
  tint.satScale = targetSat / sourceSat;
  let best = Object.assign({}, tint);
  let bestError = Infinity;
  let undershoot = 0;
  let overshoot = Infinity;
  for (let step = 0; step < CALIBRATION_STEPS; step++) {
    const result = pixelsOf(scaled(applyCube(image, colorCube(tint, CALIBRATION_CUBE_DIMENSION))));
    const [hue, sat, value] = weightedMean(entriesFor(result));
    const hueError = targetSat >= MIN_HUE_SATURATION ? signedDelta(targetHue - hue) : 0;
    const satError = targetSat - sat;
    const valueError = targetValue - value;
    const error = Math.abs(hueError) / 360 + Math.abs(satError) + Math.abs(valueError);
    if (error < bestError) { bestError = error; best = Object.assign({}, tint); }
    if (Math.abs(hueError) < 0.2 && Math.abs(satError) < CALIBRATION_TOLERANCE && Math.abs(valueError) < CALIBRATION_TOLERANCE) break;
    if (satError > 0) undershoot = Math.max(undershoot, tint.satScale);
    else overshoot = Math.min(overshoot, tint.satScale);
    tint.hueShift = signedDelta(tint.hueShift + hueError);
    tint.valueScale = clamp(tint.valueScale * (value > 0.001 ? targetValue / value : 2), 0, MAX_SCALE);
    if (targetSat === 0) tint.satScale = 0;
    else if (overshoot < Infinity && undershoot > 0) tint.satScale = Math.sqrt(undershoot * overshoot);
    else tint.satScale = clamp(tint.satScale * Math.max(sat > 0.001 ? targetSat / sat : 2, MIN_SCALE_GROWTH), 0, MAX_SCALE);
  }
  return best;
}

function resolveTarget(target, imagePath) {
  if (/^#?[0-9a-fA-F]{6}$/.test(target)) return toHex(parseHex(target));
  const hue = parseFloat(target);
  if (!isFinite(hue)) fail('color.js: target must be #rrggbb or a hue in degrees');
  const [, sourceSat, sourceValue] = dominant(imagePath);
  return toHex(hsvToRgb([wrapDegrees(hue), sourceSat, sourceValue]));
}

function pngsIn(directory) {
  const names = ObjC.deepUnwrap($.NSFileManager.defaultManager.contentsOfDirectoryAtPathError(directory, null)) || [];
  return names.filter((name) => /\.png$/i.test(name)).map((name) => directory + '/' + name);
}

function isDirectory(path) {
  const flag = Ref();
  return $.NSFileManager.defaultManager.fileExistsAtPathIsDirectory(path, flag) && flag[0];
}

function writePng(image, path) {
  const rep = $.NSBitmapImageRep.alloc.initWithCIImage(image);
  const png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
  if (!png.writeToFileAtomically(path, true)) fail('color.js: cannot write ' + path);
}

function tintImages(targetPath, targetHex, samplePath) {
  const files = isDirectory(targetPath) ? pngsIn(targetPath) : [targetPath];
  if (files.length === 0) fail('color.js: no PNG files in ' + targetPath);
  const params = calibrate(loadImage(samplePath), rgbToHsv(parseHex(targetHex)));
  const cube = colorCube(params, CUBE_DIMENSION);
  files.forEach((path) => writePng(applyCube(loadImage(path), cube), path));
  return params.hueShift.toFixed(1) + ' ' + params.satScale.toFixed(3) + ' ' + params.valueScale.toFixed(3);
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
    case 'resolve':
      if (!argv[1] || !argv[2]) fail('usage: color.js resolve <#rrggbb|hue-degrees> <source-image>');
      return resolveTarget(argv[1], argv[2]);
    case 'tint':
      if (!argv[1] || !argv[2] || !argv[3]) fail('usage: color.js tint <png-or-iconset-dir> <#rrggbb> <source-image>');
      return tintImages(argv[1], toHex(parseHex(argv[2])), argv[3]);
    default:
      fail('usage: color.js pick [#default] | dominant <image> | dominant-hex <image> | hsv <#hex> | hex <h> <s> <v> | resolve <#hex|hue> <image> | tint <png|dir> <#hex> <source-image>');
  }
}
