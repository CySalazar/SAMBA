#!/usr/bin/env python3
"""Generate SMB Mount Manager app icon at all required sizes."""

from PIL import Image, ImageDraw, ImageFont
import math
import os

def draw_icon(size):
    """Draw a macOS-style app icon for SMB Mount Manager."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    s = size  # shorthand
    margin = s * 0.08
    corner_r = s * 0.22  # macOS-style rounded rect

    # --- Background: rounded rectangle with gradient-like effect ---
    # Base color: deep blue
    bg_rect = [margin, margin, s - margin, s - margin]
    draw.rounded_rectangle(bg_rect, radius=corner_r, fill=(30, 60, 130, 255))

    # Lighter overlay on top half for depth
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    od.rounded_rectangle(bg_rect, radius=corner_r, fill=(60, 110, 200, 80))
    # Mask bottom half
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.rectangle([0, 0, s, int(s * 0.55)], fill=255)
    img = Image.composite(Image.alpha_composite(img, overlay), img, mask)
    draw = ImageDraw.Draw(img)

    # --- Hard drive icon (bottom) ---
    cx, cy = s * 0.5, s * 0.58
    hw, hh = s * 0.28, s * 0.10  # half-width, half-height of drive body

    # Drive body
    drive_rect = [cx - hw, cy - hh, cx + hw, cy + hh]
    draw.rounded_rectangle(drive_rect, radius=s * 0.03, fill=(220, 230, 245, 255), outline=(180, 195, 220, 255), width=max(1, int(s * 0.008)))

    # Drive indicator light (green = connected)
    light_r = s * 0.018
    draw.ellipse([cx + hw - s * 0.07 - light_r, cy - light_r, cx + hw - s * 0.07 + light_r, cy + light_r], fill=(50, 205, 50, 255))

    # Drive slot lines
    line_y = cy
    line_x1 = cx - hw + s * 0.05
    line_x2 = cx + hw - s * 0.12
    lw = max(1, int(s * 0.008))
    draw.line([(line_x1, line_y), (line_x2, line_y)], fill=(160, 175, 200, 255), width=lw)

    # --- Network arrows (top portion) ---
    arrow_cx, arrow_cy = s * 0.5, s * 0.33
    arrow_len = s * 0.12
    arrow_w = max(2, int(s * 0.022))
    arrow_head = s * 0.04
    arrow_color = (255, 255, 255, 230)

    # Up arrow (left)
    ax1 = arrow_cx - s * 0.08
    draw.line([(ax1, arrow_cy + arrow_len * 0.5), (ax1, arrow_cy - arrow_len * 0.5)], fill=arrow_color, width=arrow_w)
    # Arrowhead up
    draw.polygon([
        (ax1, arrow_cy - arrow_len * 0.5 - arrow_head * 0.3),
        (ax1 - arrow_head, arrow_cy - arrow_len * 0.5 + arrow_head * 0.7),
        (ax1 + arrow_head, arrow_cy - arrow_len * 0.5 + arrow_head * 0.7),
    ], fill=arrow_color)

    # Down arrow (right)
    ax2 = arrow_cx + s * 0.08
    draw.line([(ax2, arrow_cy - arrow_len * 0.5), (ax2, arrow_cy + arrow_len * 0.5)], fill=arrow_color, width=arrow_w)
    # Arrowhead down
    draw.polygon([
        (ax2, arrow_cy + arrow_len * 0.5 + arrow_head * 0.3),
        (ax2 - arrow_head, arrow_cy + arrow_len * 0.5 - arrow_head * 0.7),
        (ax2 + arrow_head, arrow_cy + arrow_len * 0.5 - arrow_head * 0.7),
    ], fill=arrow_color)

    # --- Connection dots around arrows ---
    dot_r = s * 0.012
    dot_color = (180, 220, 255, 200)
    for angle_deg in [0, 60, 120, 180, 240, 300]:
        rad = math.radians(angle_deg)
        dx = arrow_cx + s * 0.16 * math.cos(rad)
        dy = arrow_cy + s * 0.16 * math.sin(rad)
        draw.ellipse([dx - dot_r, dy - dot_r, dx + dot_r, dy + dot_r], fill=dot_color)

    # --- "SMB" text at bottom ---
    text_y = cy + hh + s * 0.04
    font_size = max(8, int(s * 0.08))
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size)
    except Exception:
        try:
            font = ImageFont.truetype("/System/Library/Fonts/SFNSMono.ttf", font_size)
        except Exception:
            font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), "SMB", font=font)
    tw = bbox[2] - bbox[0]
    draw.text((cx - tw / 2, text_y), "SMB", fill=(255, 255, 255, 220), font=font)

    return img


# macOS icon sizes: size@scale
icon_specs = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

output_dir = "SMBMountManager/Assets.xcassets/AppIcon.appiconset"

contents_images = []
for base_size, scale in icon_specs:
    pixel_size = base_size * scale
    img = draw_icon(pixel_size)

    suffix = "" if scale == 1 else f"@{scale}x"
    filename = f"icon_{base_size}x{base_size}{suffix}.png"
    filepath = os.path.join(output_dir, filename)
    img.save(filepath, "PNG")
    print(f"  Generated {filename} ({pixel_size}x{pixel_size}px)")

    contents_images.append({
        "filename": filename,
        "idiom": "mac",
        "scale": f"{scale}x",
        "size": f"{base_size}x{base_size}"
    })

# Write Contents.json
import json
contents = {
    "images": contents_images,
    "info": {
        "author": "xcode",
        "version": 1
    }
}
with open(os.path.join(output_dir, "Contents.json"), "w") as f:
    json.dump(contents, f, indent=2)

print("\nDone! All icon sizes generated.")
