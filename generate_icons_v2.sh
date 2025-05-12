#!/bin/bash

# Navigate to the AppIcon.appiconset directory
cd "$(dirname "$0")/WhisperNote/Assets.xcassets/AppIcon.appiconset"

# Create a temporary directory
mkdir -p temp

# First, create a high-quality PNG from the SVG using Safari's rendering engine
# This will open the SVG in Safari and take a screenshot
osascript <<EOF
tell application "Safari"
    open "file://$(pwd)/icon.svg"
    delay 2
    set bounds of window 1 to {100, 100, 1124, 1124}
    delay 1
    tell application "System Events"
        keystroke "4" using {command down, shift down}
        delay 0.5
        click at {612, 612}
        delay 0.5
        click at {1124, 1124}
    end tell
    delay 1
    close window 1
end tell
EOF

# Wait for the screenshot to be saved to the clipboard
sleep 2

# Save the screenshot to a file
osascript <<EOF
tell application "System Events"
    keystroke "v" using {command down}
    delay 0.5
    keystroke "s" using {command down}
    delay 0.5
    keystroke "$(pwd)/temp/icon_1024.png"
    delay 0.5
    keystroke return
    delay 1
end tell
EOF

# Generate all required sizes
cd temp

# Mac icon sizes
sips -z 16 16 icon_1024.png --out ../icon_16x16.png
sips -z 32 32 icon_1024.png --out ../icon_16x16@2x.png
sips -z 32 32 icon_1024.png --out ../icon_32x32.png
sips -z 64 64 icon_1024.png --out ../icon_32x32@2x.png
sips -z 128 128 icon_1024.png --out ../icon_128x128.png
sips -z 256 256 icon_1024.png --out ../icon_128x128@2x.png
sips -z 256 256 icon_1024.png --out ../icon_256x256.png
sips -z 512 512 icon_1024.png --out ../icon_256x256@2x.png
sips -z 512 512 icon_1024.png --out ../icon_512x512.png
sips -z 1024 1024 icon_1024.png --out ../icon_512x512@2x.png

# Clean up
cd ..
rm -rf temp

echo "App icons generated successfully!"
