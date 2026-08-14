from PIL import Image, ImageDraw, ImageFont

W, H = 320, 180
BG = (0x0D, 0x0D, 0x0D, 255)
ACCENT = (0xD8, 0x5A, 0x30, 255)
WHITE = (255, 255, 255, 255)

banner = Image.new("RGBA", (W, H), BG)

icon = Image.open("assets/icon/app_icon.png").convert("RGBA")
icon_h = 110
icon = icon.resize((icon_h, icon_h), Image.LANCZOS)
icon_x = 16
banner.paste(icon, (icon_x, (H - icon_h) // 2), icon)

draw = ImageDraw.Draw(banner)
font_bold = ImageFont.truetype("assets/fonts/Inter-Variable.ttf", 26)
try:
    font_bold.set_variation_by_axes([700])
except Exception:
    pass

text_x = icon_x + icon_h + 14
bbox_b = draw.textbbox((0, 0), "Barclay", font=font_bold)
bw = bbox_b[2] - bbox_b[0]
bbox_f = draw.textbbox((0, 0), "Flix", font=font_bold)
fw = bbox_f[2] - bbox_f[0]
assert text_x + bw + fw <= W - 10, (text_x, bw, fw)
y = H // 2 - (bbox_b[3] - bbox_b[1]) // 2 - bbox_b[1]
draw.text((text_x, y), "Barclay", font=font_bold, fill=WHITE)
draw.text((text_x + bw, y), "Flix", font=font_bold, fill=ACCENT)

banner.convert("RGB").save("android/app/src/main/res/drawable-xhdpi/tv_banner.png")
print("banner written")
