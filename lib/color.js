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
const BACKGROUND_MIN_SATURATION = 0.3;
const SPAN_START = 0.3;
const SPAN_END = 0.7;
const SPAN_MIN_FILL = 0.9;
const BAND_NEAR = 0.03;
const BAND_FAR = 0.09;
const MAX_SHADE_ALPHA = 0.3;
const SRGB_LUMA = [0.2126, 0.7152, 0.0722];
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

function saturationWeight(r, g, b) {
  const max = Math.max(r, g, b);
  return smoothstep(WEIGHT_LOW, WEIGHT_HIGH, max === 0 ? 0 : (max - Math.min(r, g, b)) / max);
}

function buildCubes(target, dimension) {
  const flat = new Float32Array(dimension * dimension * dimension * 4);
  const mask = new Float32Array(flat.length);
  const last = dimension - 1;
  let offset = 0;
  for (let b = 0; b < dimension; b++) {
    for (let g = 0; g < dimension; g++) {
      for (let r = 0; r < dimension; r++) {
        const rgb = [r / last, g / last, b / last];
        const weight = saturationWeight(rgb[0], rgb[1], rgb[2]);
        for (let channel = 0; channel < 3; channel++) {
          flat[offset + channel] = rgb[channel] + (target[channel] - rgb[channel]) * weight;
          mask[offset + channel] = weight;
        }
        flat[offset + 3] = 1;
        mask[offset + 3] = 1;
        offset += 4;
      }
    }
  }
  return [flat, mask].map((floats) => {
    const data = $.NSData.alloc.initWithBase64EncodedStringOptions($(base64Of(new Uint8Array(floats.buffer))), 0);
    if (!data || data.isNil()) fail('color.js: cannot build the color cube');
    return { data, dimension };
  });
}

function applyCube(image, cube) {
  return applyFilter('CIColorCube', image, { inputCubeDimension: $(cube.dimension), inputCubeData: cube.data });
}

function lumaOf(rgb) {
  return rgb.reduce((sum, channel, index) => sum + channel * SRGB_LUMA[index], 0);
}

function averageRgb(pixels, rows, columns) {
  const sum = [0, 0, 0];
  let count = 0;
  rows.forEach((row) => {
    for (let x = columns[0]; x < columns[1]; x++) {
      const pixel = pixels[row * SAMPLE_SIZE + x];
      if (!pixel || pixel[1] < BACKGROUND_MIN_SATURATION) continue;
      hsvToRgb(pixel).forEach((channel, index) => { sum[index] += channel; });
      count++;
    }
  });
  return count === 0 ? null : sum.map((channel) => channel / count);
}

function rowRange(from, to) {
  const rows = [];
  for (let row = Math.ceil(from); row < Math.floor(to); row++) rows.push(row);
  return rows;
}

function measureShading(image) {
  const pixels = pixelsOf(scaled(image));
  const columns = [Math.round(SAMPLE_SIZE * SPAN_START), Math.round(SAMPLE_SIZE * SPAN_END)];
  const isFilled = (row) => {
    let filled = 0;
    for (let x = columns[0]; x < columns[1]; x++) {
      const pixel = pixels[row * SAMPLE_SIZE + x];
      if (pixel && pixel[1] >= BACKGROUND_MIN_SATURATION) filled++;
    }
    return filled >= (columns[1] - columns[0]) * SPAN_MIN_FILL;
  };
  let first = 0;
  while (first < SAMPLE_SIZE && !isFilled(first)) first++;
  let last = SAMPLE_SIZE - 1;
  while (last > first && !isFilled(last)) last--;
  const none = { alpha: 0, top: 0, bottom: 1 };
  if (first >= last) return none;
  const top = first;
  const bottom = last + 1;
  const height = bottom - top;
  const topColor = averageRgb(pixels, rowRange(top + height * BAND_NEAR, top + height * BAND_FAR), columns);
  const bottomColor = averageRgb(pixels, rowRange(bottom - height * BAND_FAR, bottom - height * BAND_NEAR), columns);
  if (!topColor || !bottomColor) return none;
  return {
    alpha: clamp(1 - lumaOf(bottomColor) / lumaOf(topColor), 0, MAX_SHADE_ALPHA),
    top: top / SAMPLE_SIZE,
    bottom: bottom / SAMPLE_SIZE,
  };
}

function shadeGradient(extent, shading) {
  const gradient = $.CIFilter.filterWithName('CILinearGradient');
  const height = extent.size.height;
  const x = extent.origin.x + extent.size.width / 2;
  gradient.setValueForKey($.CIVector.vectorWithXY(x, extent.origin.y + height * (1 - shading.bottom)), 'inputPoint0');
  gradient.setValueForKey($.CIVector.vectorWithXY(x, extent.origin.y + height * (1 - shading.top)), 'inputPoint1');
  gradient.setValueForKey($.CIColor.colorWithRedGreenBlueAlpha(0, 0, 0, shading.alpha), 'inputColor0');
  gradient.setValueForKey($.CIColor.colorWithRedGreenBlueAlpha(0, 0, 0, 0), 'inputColor1');
  return gradient.valueForKey('outputImage').imageByCroppingToRect(extent);
}

function tintOne(image, cubes, shading) {
  const extent = image.extent;
  const encoded = applyFilter('CILinearToSRGBToneCurve', image);
  const flat = applyCube(encoded, cubes.flat);
  const mask = applyCube(encoded, cubes.mask);
  const shaded = applyFilter('CISourceOverCompositing', shadeGradient(extent, shading), { inputBackgroundImage: flat });
  const blended = applyFilter('CIBlendWithMask', shaded, { inputBackgroundImage: flat, inputMaskImage: mask });
  return applyFilter('CISRGBToneCurveToLinear', blended).imageByCroppingToRect(extent);
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
  const shading = measureShading(loadImage(samplePath));
  const [flat, mask] = buildCubes(parseHex(targetHex), CUBE_DIMENSION);
  files.forEach((path) => writePng(tintOne(loadImage(path), { flat, mask }, shading), path));
  return 'shade ' + shading.alpha.toFixed(3);
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
