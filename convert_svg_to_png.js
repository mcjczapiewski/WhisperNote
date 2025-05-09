const fs = require('fs');
const path = require('path');
const svg2png = require('svg2png');
const { execSync } = require('child_process');

// Paths
const scriptDir = __dirname;
const svgPath = path.join(scriptDir, 'WhisperNote/Assets.xcassets/AppIcon.appiconset/icon.svg');
const outputDir = path.join(scriptDir, 'WhisperNote/Assets.xcassets/AppIcon.appiconset');
const tempPngPath = path.join(outputDir, 'icon_1024.png');

// Read SVG file
const svgBuffer = fs.readFileSync(svgPath);

// Convert SVG to PNG
svg2png(svgBuffer, { width: 1024, height: 1024 })
  .then(pngBuffer => {
    // Save PNG file
    fs.writeFileSync(tempPngPath, pngBuffer);
    console.log(`Converted ${svgPath} to ${tempPngPath}`);

    // Generate all required icon sizes
    const sizes = [
      { name: 'icon_16x16.png', width: 16, height: 16 },
      { name: 'icon_16x16@2x.png', width: 32, height: 32 },
      { name: 'icon_32x32.png', width: 32, height: 32 },
      { name: 'icon_32x32@2x.png', width: 64, height: 64 },
      { name: 'icon_128x128.png', width: 128, height: 128 },
      { name: 'icon_128x128@2x.png', width: 256, height: 256 },
      { name: 'icon_256x256.png', width: 256, height: 256 },
      { name: 'icon_256x256@2x.png', width: 512, height: 512 },
      { name: 'icon_512x512.png', width: 512, height: 512 },
      { name: 'icon_512x512@2x.png', width: 1024, height: 1024 },
    ];

    sizes.forEach(size => {
      const outputPath = path.join(outputDir, size.name);
      execSync(`sips -z ${size.height} ${size.width} ${tempPngPath} --out ${outputPath}`);
      console.log(`Generated ${outputPath}`);
    });

    // Update Contents.json
    const contentsJson = {
      images: [
        {
          filename: 'icon_16x16.png',
          idiom: 'mac',
          scale: '1x',
          size: '16x16'
        },
        {
          filename: 'icon_16x16@2x.png',
          idiom: 'mac',
          scale: '2x',
          size: '16x16'
        },
        {
          filename: 'icon_32x32.png',
          idiom: 'mac',
          scale: '1x',
          size: '32x32'
        },
        {
          filename: 'icon_32x32@2x.png',
          idiom: 'mac',
          scale: '2x',
          size: '32x32'
        },
        {
          filename: 'icon_128x128.png',
          idiom: 'mac',
          scale: '1x',
          size: '128x128'
        },
        {
          filename: 'icon_128x128@2x.png',
          idiom: 'mac',
          scale: '2x',
          size: '128x128'
        },
        {
          filename: 'icon_256x256.png',
          idiom: 'mac',
          scale: '1x',
          size: '256x256'
        },
        {
          filename: 'icon_256x256@2x.png',
          idiom: 'mac',
          scale: '2x',
          size: '256x256'
        },
        {
          filename: 'icon_512x512.png',
          idiom: 'mac',
          scale: '1x',
          size: '512x512'
        },
        {
          filename: 'icon_512x512@2x.png',
          idiom: 'mac',
          scale: '2x',
          size: '512x512'
        }
      ],
      info: {
        author: 'xcode',
        version: 1
      }
    };

    fs.writeFileSync(path.join(outputDir, 'Contents.json'), JSON.stringify(contentsJson, null, 2));
    console.log('Updated Contents.json');

    // Clean up
    fs.unlinkSync(tempPngPath);
    console.log('App icons generated successfully!');
  })
  .catch(err => {
    console.error('Error:', err);
  });
