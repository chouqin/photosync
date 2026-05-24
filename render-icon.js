const sharp = require('sharp');
const fs = require('fs');

async function render() {
    const svg = fs.readFileSync('icon.svg');
    
    // Try to render SVG to PNG at multiple sizes
    const sizes = [1024, 180, 120, 87, 80, 60, 58, 40, 29, 20];
    
    for (const size of sizes) {
        await sharp(svg, { density: 300 })
            .resize(size, size)
            .png()
            .toFile(`ios/PhotoSync/Assets.xcassets/AppIcon.appiconset/icon-${size}.png`);
        console.log(`Generated icon-${size}.png`);
    }
    
    // Also save a high-res version in the project root
    await sharp(svg, { density: 300 })
        .resize(1024, 1024)
        .png()
        .toFile('app-icon-1024.png');
    console.log('Generated app-icon-1024.png');
}

render().catch(err => {
    console.error('Error:', err.message);
    process.exit(1);
});
