const sharp = require('sharp');
const fs = require('fs');

const svg = fs.readFileSync('icon.svg');
const outDir = 'ios/PhotoSync/Assets.xcassets/AppIcon.appiconset';

// iOS app icon sizes (as of iOS 17)
// idiom: iphone + ipad + ios-marketing
const icons = [
  { size: 20, scales: [2, 3], idiom: 'iphone' },
  { size: 29, scales: [2, 3], idiom: 'iphone' },
  { size: 40, scales: [2, 3], idiom: 'iphone' },
  { size: 60, scales: [2, 3], idiom: 'iphone' },
  { size: 20, scales: [1, 2], idiom: 'ipad' },
  { size: 29, scales: [1, 2], idiom: 'ipad' },
  { size: 40, scales: [1, 2], idiom: 'ipad' },
  { size: 76, scales: [1, 2], idiom: 'ipad' },
  { size: 83.5, scales: [2], idiom: 'ipad' },
  { size: 1024, scales: [1], idiom: 'ios-marketing' },
];

async function generate() {
  const images = [];

  for (const icon of icons) {
    for (const scale of icon.scales) {
      const px = Math.round(icon.size * scale);
      const filename = `${icon.idiom}-${icon.size}@${scale}x.png`;
      
      await sharp(svg, { density: 300 })
        .resize(px, px)
        .png()
        .toFile(`${outDir}/${filename}`);
      
      images.push({
        size: `${icon.size}x${icon.size}`,
        idiom: icon.idiom,
        filename: filename,
        scale: `${scale}x`
      });
      
      console.log(`Generated ${filename} (${px}x${px})`);
    }
  }

  // Write Contents.json
  const contents = {
    images: images,
    info: {
      author: "xcode",
      version: 1
    }
  };
  
  fs.writeFileSync(`${outDir}/Contents.json`, JSON.stringify(contents, null, 2));
  console.log(`\nWrote Contents.json with ${images.length} icons`);
  
  // Also save master copies in icons/ folder
  await sharp(svg, { density: 300 })
    .resize(1024, 1024)
    .png()
    .toFile('icons/app-icon-1024.png');
  console.log('Saved icons/app-icon-1024.png');
}

generate().catch(err => {
  console.error('Error:', err);
  process.exit(1);
});
