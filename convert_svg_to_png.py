#!/usr/bin/env python3

import os
import sys
import cairosvg
import subprocess

def convert_svg_to_png(svg_path, output_path, width, height):
    """Convert SVG to PNG using cairosvg."""
    cairosvg.svg2png(url=svg_path, write_to=output_path, output_width=width, output_height=height)
    print(f"Converted {svg_path} to {output_path}")

def generate_mac_icons(base_png_path, output_dir):
    """Generate all required icon sizes for macOS."""
    sizes = [
        ("icon_16x16.png", 16, 16),
        ("icon_16x16@2x.png", 32, 32),
        ("icon_32x32.png", 32, 32),
        ("icon_32x32@2x.png", 64, 64),
        ("icon_128x128.png", 128, 128),
        ("icon_128x128@2x.png", 256, 256),
        ("icon_256x256.png", 256, 256),
        ("icon_256x256@2x.png", 512, 512),
        ("icon_512x512.png", 512, 512),
        ("icon_512x512@2x.png", 1024, 1024),
    ]
    
    for filename, width, height in sizes:
        output_path = os.path.join(output_dir, filename)
        subprocess.run(["sips", "-z", str(height), str(width), base_png_path, "--out", output_path])
        print(f"Generated {output_path}")

def update_contents_json(output_dir):
    """Update Contents.json file."""
    contents_json = {
        "images": [
            {
                "filename": "icon_16x16.png",
                "idiom": "mac",
                "scale": "1x",
                "size": "16x16"
            },
            {
                "filename": "icon_16x16@2x.png",
                "idiom": "mac",
                "scale": "2x",
                "size": "16x16"
            },
            {
                "filename": "icon_32x32.png",
                "idiom": "mac",
                "scale": "1x",
                "size": "32x32"
            },
            {
                "filename": "icon_32x32@2x.png",
                "idiom": "mac",
                "scale": "2x",
                "size": "32x32"
            },
            {
                "filename": "icon_128x128.png",
                "idiom": "mac",
                "scale": "1x",
                "size": "128x128"
            },
            {
                "filename": "icon_128x128@2x.png",
                "idiom": "mac",
                "scale": "2x",
                "size": "128x128"
            },
            {
                "filename": "icon_256x256.png",
                "idiom": "mac",
                "scale": "1x",
                "size": "256x256"
            },
            {
                "filename": "icon_256x256@2x.png",
                "idiom": "mac",
                "scale": "2x",
                "size": "256x256"
            },
            {
                "filename": "icon_512x512.png",
                "idiom": "mac",
                "scale": "1x",
                "size": "512x512"
            },
            {
                "filename": "icon_512x512@2x.png",
                "idiom": "mac",
                "scale": "2x",
                "size": "512x512"
            }
        ],
        "info": {
            "author": "xcode",
            "version": 1
        }
    }
    
    import json
    with open(os.path.join(output_dir, "Contents.json"), "w") as f:
        json.dump(contents_json, f, indent=2)
    
    print(f"Updated Contents.json")

def main():
    # Get the directory of the script
    script_dir = os.path.dirname(os.path.abspath(__file__))
    
    # Set paths
    svg_path = os.path.join(script_dir, "WhisperNote/Assets.xcassets/AppIcon.appiconset/icon.svg")
    output_dir = os.path.join(script_dir, "WhisperNote/Assets.xcassets/AppIcon.appiconset")
    temp_png_path = os.path.join(output_dir, "icon_1024.png")
    
    # Convert SVG to PNG
    convert_svg_to_png(svg_path, temp_png_path, 1024, 1024)
    
    # Generate all required icon sizes
    generate_mac_icons(temp_png_path, output_dir)
    
    # Update Contents.json
    update_contents_json(output_dir)
    
    # Clean up
    os.remove(temp_png_path)
    
    print("App icons generated successfully!")

if __name__ == "__main__":
    main()
