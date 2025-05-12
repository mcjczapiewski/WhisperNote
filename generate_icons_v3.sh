#!/bin/bash

# Navigate to the AppIcon.appiconset directory
cd "$(dirname "$0")/WhisperNote/Assets.xcassets/AppIcon.appiconset"

# Create a temporary directory
mkdir -p temp

# Use Safari to render the SVG and take a screenshot
open -a Safari icon.svg
sleep 2

# Now let's use a different approach - let's create a simple HTML file that embeds the SVG
cat > temp/icon.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Icon</title>
    <style>
        body {
            margin: 0;
            padding: 0;
            background-color: transparent;
        }
        svg {
            width: 1024px;
            height: 1024px;
        }
    </style>
</head>
<body>
    <object data="file://$(pwd)/icon.svg" type="image/svg+xml" width="1024" height="1024"></object>
</body>
</html>
EOF

# Open the HTML file in Safari
open -a Safari temp/icon.html
sleep 2

# Now let's use a different approach - let's use the Preview app to convert the SVG
cp icon.svg temp/icon.svg
open -a Preview temp/icon.svg
sleep 2

# Export as PNG from Preview (manual step)
echo "Please export the SVG as PNG from Preview app with size 1024x1024 and save it as 'icon_1024.png' in the AppIcon.appiconset directory"
echo "Press Enter when done..."
read

# Check if the file exists
if [ ! -f "icon_1024.png" ]; then
    echo "icon_1024.png not found. Please export the SVG as PNG from Preview app and try again."
    exit 1
fi

# Generate all required sizes
sips -z 16 16 icon_1024.png --out icon_16x16.png
sips -z 32 32 icon_1024.png --out icon_16x16@2x.png
sips -z 32 32 icon_1024.png --out icon_32x32.png
sips -z 64 64 icon_1024.png --out icon_32x32@2x.png
sips -z 128 128 icon_1024.png --out icon_128x128.png
sips -z 256 256 icon_1024.png --out icon_128x128@2x.png
sips -z 256 256 icon_1024.png --out icon_256x256.png
sips -z 512 512 icon_1024.png --out icon_256x256@2x.png
sips -z 512 512 icon_1024.png --out icon_512x512.png
cp icon_1024.png icon_512x512@2x.png

# Clean up
rm -rf temp

echo "App icons generated successfully!"
