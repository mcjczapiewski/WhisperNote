#!/bin/bash

# Navigate to the AppIcon.appiconset directory
cd "$(dirname "$0")/WhisperNote/Assets.xcassets/AppIcon.appiconset"

# Convert SVG to PNG at 1024x1024 (highest resolution)
/usr/bin/qlmanage -t -s 1024 -o . icon.svg
mv icon.svg.png icon_1024.png

# Generate all required sizes
mkdir -p generated

# Mac icon sizes
sips -z 16 16 icon_1024.png --out generated/icon_16x16.png
sips -z 32 32 icon_1024.png --out generated/icon_16x16@2x.png
sips -z 32 32 icon_1024.png --out generated/icon_32x32.png
sips -z 64 64 icon_1024.png --out generated/icon_32x32@2x.png
sips -z 128 128 icon_1024.png --out generated/icon_128x128.png
sips -z 256 256 icon_1024.png --out generated/icon_128x128@2x.png
sips -z 256 256 icon_1024.png --out generated/icon_256x256.png
sips -z 512 512 icon_1024.png --out generated/icon_256x256@2x.png
sips -z 512 512 icon_1024.png --out generated/icon_512x512.png
sips -z 1024 1024 icon_1024.png --out generated/icon_512x512@2x.png

# Update Contents.json
cat > Contents.json << EOF
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

# Move generated icons to the main directory
mv generated/* .
rmdir generated

# Clean up
rm icon_1024.png

echo "App icons generated successfully!"
