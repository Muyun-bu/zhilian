from pathlib import Path
from PIL import Image
import sys

source, target = map(Path, sys.argv[1:3])
image = Image.open(source).convert("RGBA")
image.save(target, format="ICNS", append_images=[], sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
