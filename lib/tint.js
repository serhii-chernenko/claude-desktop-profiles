ObjC.import('AppKit');
ObjC.import('CoreImage');
ObjC.import('stdlib');

function fail(message) {
  const data = $(message + '\n').dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardError.writeData(data);
  $.exit(1);
}

function tintFile(path, angleDegrees, saturation) {
  const url = $.NSURL.fileURLWithPath(path);
  let image = $.CIImage.imageWithContentsOfURL(url);
  if (!image || image.isNil()) fail('tint.js: cannot read image ' + path);

  const hue = $.CIFilter.filterWithName('CIHueAdjust');
  hue.setValueForKey(image, 'inputImage');
  hue.setValueForKey($(angleDegrees * Math.PI / 180), 'inputAngle');
  image = hue.valueForKey('outputImage');

  const controls = $.CIFilter.filterWithName('CIColorControls');
  controls.setValueForKey(image, 'inputImage');
  controls.setValueForKey($(saturation), 'inputSaturation');
  image = controls.valueForKey('outputImage');

  const rep = $.NSBitmapImageRep.alloc.initWithCIImage(image);
  const png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
  if (!png.writeToFileAtomically(path, true)) fail('tint.js: cannot write ' + path);
}

function pngsIn(directory) {
  const names = ObjC.deepUnwrap($.NSFileManager.defaultManager.contentsOfDirectoryAtPathError(directory, null)) || [];
  return names.filter((name) => /\.png$/i.test(name)).map((name) => directory + '/' + name);
}

function isDirectory(path) {
  const flag = Ref();
  return $.NSFileManager.defaultManager.fileExistsAtPathIsDirectory(path, flag) && flag[0];
}

function run(argv) {
  if (argv.length < 2) fail('usage: tint.js <png-or-iconset-dir> <hue-degrees> [saturation]');
  const angle = parseFloat(argv[1]);
  const saturation = parseFloat(argv[2] || '1');
  if (!isFinite(angle) || !isFinite(saturation)) fail('tint.js: hue and saturation must be numbers');
  const targets = isDirectory(argv[0]) ? pngsIn(argv[0]) : [argv[0]];
  if (targets.length === 0) fail('tint.js: no PNG files in ' + argv[0]);
  targets.forEach((path) => tintFile(path, angle, saturation));
  return '';
}
