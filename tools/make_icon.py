# Генерирует иконку приложения (AppIcon.appiconset). Запуск: python3 tools/make_icon.py
import json, os
from PIL import Image, ImageDraw, ImageFont
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "Assets.xcassets")
ICON = os.path.join(OUT, "AppIcon.appiconset")
os.makedirs(ICON, exist_ok=True)
with open(os.path.join(OUT, "Contents.json"), "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}}, f)

def draw(size):
    s = 1024
    im = Image.new("RGB", (s, s), (38, 42, 51))
    d = ImageDraw.Draw(im)
    # чек
    x0, y0, x1, y1 = 262, 170, 762, 854
    d.rounded_rectangle((x0, y0, x1, y1), radius=36, fill=(250, 250, 248))
    # зубчатый низ
    n = 10; w = (x1 - x0) / n
    for i in range(n):
        cx = x0 + w * i
        d.polygon([(cx, y1 - 2), (cx + w / 2, y1 + 44), (cx + w, y1 - 2)], fill=(250, 250, 248))
    for i, ww in enumerate([360, 300, 340, 260]):
        d.rounded_rectangle((322, 270 + i * 70, 322 + ww, 292 + i * 70), radius=11, fill=(190, 194, 202))
    d.rounded_rectangle((322, 600, 702, 612), radius=6, fill=(210, 213, 219))
    d.rounded_rectangle((322, 650, 560, 760), radius=20, fill=(224, 122, 47))
    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 86)
    except Exception:
        font = ImageFont.load_default()
    d.text((352, 672), "₽ 0", font=font, fill=(255, 255, 255))
    return im.resize((size, size), Image.LANCZOS) if size != s else im

images = []
ios = draw(1024); ios.save(os.path.join(ICON, "ios-1024.png"))
images.append({"filename": "ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"})
for base in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = base * scale
        name = f"mac-{base}@{scale}x.png"
        draw(px).save(os.path.join(ICON, name))
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{base}x{base}"})
with open(os.path.join(ICON, "Contents.json"), "w") as f:
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
print("ok")
