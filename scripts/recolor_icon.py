import numpy as np
from PIL import Image

SRC = "assets/icon/app_icon.png"

BG_OLD = np.array([13, 17, 23], dtype=np.float64)
FG_OLD = np.array([46, 124, 246], dtype=np.float64)

BG_NEW = np.array([0x0D, 0x0D, 0x0D], dtype=np.float64)
FG_NEW = np.array([0xD8, 0x5A, 0x30], dtype=np.float64)

im = Image.open(SRC).convert("RGBA")
arr = np.asarray(im).astype(np.float64)
rgb = arr[..., :3]
alpha = arr[..., 3]

axis = FG_OLD - BG_OLD
axis_len2 = float(np.dot(axis, axis))
delta = rgb - BG_OLD
t = (delta @ axis) / axis_len2
t = np.clip(t, 0.0, 1.0)

new_rgb = BG_NEW + t[..., None] * (FG_NEW - BG_NEW)
out = np.dstack([new_rgb, alpha]).clip(0, 255).astype(np.uint8)

Image.fromarray(out, mode="RGBA").save(SRC)
print("recolored", SRC)
