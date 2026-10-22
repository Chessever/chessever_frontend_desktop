#!/usr/bin/env node
// Compose genuine Mac app captures without redrawing or changing their UI.
// Requires sharp (it is also available in the Codex workspace runtime).
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const sharp = require('sharp');

const root = path.resolve(__dirname, '..');
const output = path.resolve(process.argv[2] || path.join(root, 'output/mac-app-store-screenshots'));
const fontfile = path.join(root, 'assets/fonts/Geist-VariableFont_wght.ttf');
const dimensions = { width: 2880, height: 1800 };
const slides = [
  {
    file: '01-live-events.png',
    title: 'Live chess, board by board.',
    subtitle: 'Follow tournaments from around the world in one place.',
    crop: { left: 480, top: 92, width: 2880, height: 1728 },
  },
  {
    file: '02-live-analysis.png',
    title: 'Analyze with Stockfish.',
    subtitle: 'Evaluation, candidate lines and notation in one workspace.',
    crop: { left: 480, top: 92, width: 2880, height: 1852 },
  },
  {
    file: '03-opening-explorer.png',
    title: 'Make opening preparation count.',
    subtitle: 'Explore results and games from the current position.',
    crop: { left: 480, top: 92, width: 2880, height: 1852 },
  },
  {
    file: '04-player-profile.png',
    title: 'Understand the player behind the rating.',
    subtitle: 'Rating history and performance, from both sides of the board.',
    crop: { left: 480, top: 92, width: 2880, height: 1380 },
  },
  {
    file: '05-event-calendar.png',
    title: 'Keep your chess calendar in view.',
    subtitle: 'Browse events by date, location and format.',
    crop: { left: 480, top: 92, width: 2880, height: 1788 },
  },
];

function escapeMarkup(value) {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

async function textImage(value, size, color, weight) {
  return sharp({ text: {
    text: `<span foreground="${color}">${escapeMarkup(value)}</span>`,
    fontfile,
    font: `Geist ${weight} ${size}`,
    rgba: true,
    dpi: 72,
  } }).png().toBuffer({ resolveWithObject: true });
}

async function main() {
  const storeDir = path.join(output, 'en-US');
  const cleanDir = path.join(output, 'clean');
  await fs.mkdir(storeDir, { recursive: true });
  await fs.mkdir(cleanDir, { recursive: true });
  const brand = await textImage('ChessEver for Mac', 30, '#a2a6a8', 'Medium');
  const manifest = [];
  for (const slide of slides) {
    const source = path.join(output, 'raw', slide.file);
    const bytes = await fs.readFile(source);
    const metadata = await sharp(bytes).metadata();
    if (metadata.width !== 3360 || metadata.height !== 1944) {
      throw new Error(`${slide.file}: inspect and update the crop for ${metadata.width}x${metadata.height}`);
    }
    // Crop only to entire product regions: omit account, screen-sharing and
    // window chrome. Never paint over names, numbers, graphs or controls.
    const product = await sharp(bytes).extract(slide.crop)
      .resize({ width: 2736, height: 1480, fit: 'inside', withoutEnlargement: true })
      .toColourspace('srgb').removeAlpha().png()
      .toBuffer({ resolveWithObject: true });
    const title = await textImage(slide.title, 82, '#f5f6f6', 'Semi-Bold');
    const subtitle = await textImage(slide.subtitle, 38, '#aeb2b4', 'Regular');
    if (title.info.width > 2600 || subtitle.info.width > 2600) {
      throw new Error(`${slide.file}: caption exceeds the safe text width`);
    }
    const left = Math.round((dimensions.width - product.info.width) / 2);
    await sharp({ create: { ...dimensions, channels: 3, background: '#0b0b0d' } })
      .composite([
        { input: title.data, left: 72, top: 56 },
        { input: subtitle.data, left: 76, top: 160 },
        { input: brand.data, left: dimensions.width - 76 - brand.info.width, top: 172 },
        { input: product.data, left, top: 268 },
      ])
      .toColourspace('srgb').removeAlpha().png({ compressionLevel: 9 })
      .toFile(path.join(storeDir, slide.file));
    // A caption-free variant is retained for future listings or localization.
    const cleanProduct = await sharp(bytes).extract(slide.crop)
      .resize({ ...dimensions, fit: 'contain', background: '#0b0b0d' })
      .toColourspace('srgb').removeAlpha().png().toBuffer();
    await fs.writeFile(path.join(cleanDir, slide.file), cleanProduct);
    manifest.push({ ...slide, sourceVersion: '22.15.0+476',
      sourceSha256: crypto.createHash('sha256').update(bytes).digest('hex'),
      output: `en-US/${slide.file}`, ...dimensions });
  }
  const thumbs = await Promise.all(slides.map(async (slide) => ({
    input: await sharp(path.join(storeDir, slide.file)).resize(960, 600).png().toBuffer(),
  })));
  await sharp({ create: { width: 2880, height: 1200, channels: 3, background: '#151517' } })
    .composite(thumbs.map((thumb, i) => ({ ...thumb, left: i % 3 * 960, top: Math.floor(i / 3) * 600 })))
    .png().toFile(path.join(output, 'contact-sheet.png'));
  await fs.writeFile(path.join(output, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  console.log(`Prepared ${slides.length} sRGB screenshots at 2880x1800 in ${storeDir}`);
}

main().catch((error) => { console.error(error.message); process.exitCode = 1; });
