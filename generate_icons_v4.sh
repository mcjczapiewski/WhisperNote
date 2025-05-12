#!/bin/bash

# Navigate to the AppIcon.appiconset directory
cd "$(dirname "$0")/WhisperNote/Assets.xcassets/AppIcon.appiconset"

# Create a temporary directory
mkdir -p temp

# Copy the SVG file to the temp directory
cp icon.svg temp/

# Create a simple HTML file that displays the SVG
cat > temp/icon.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Icon</title>
    <style>
        body {
            margin: 0;
            padding: 0;
            background-color: white;
        }
        .icon-container {
            width: 1024px;
            height: 1024px;
            display: flex;
            justify-content: center;
            align-items: center;
        }
        svg {
            width: 1024px;
            height: 1024px;
        }
    </style>
</head>
<body>
    <div class="icon-container">
        <img src="icon.svg" width="1024" height="1024">
    </div>
</body>
</html>
EOF

# Open the HTML file in Safari
open -a Safari "$(pwd)/temp/icon.html"

# Wait for the user to take a screenshot
echo "Please take a screenshot of the SVG in Safari (Command+Shift+4)"
echo "Make sure to capture the entire SVG at 1024x1024 resolution"
echo "Save the screenshot as 'icon_1024.png' in the AppIcon.appiconset directory"
echo "Press Enter when done..."
read

# Check if the file exists
if [ ! -f "icon_1024.png" ]; then
    echo "icon_1024.png not found. Please take a screenshot and save it as 'icon_1024.png' in the AppIcon.appiconset directory."
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
