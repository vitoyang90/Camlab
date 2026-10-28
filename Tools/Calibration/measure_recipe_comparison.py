#!/usr/bin/env python3
"""Measure aligned, sRGB PNGs emitted by render_recipe_comparison.py.

Usage: python3 Tools/Calibration/measure_recipe_comparison.py COMPARISON_DIRECTORY
Requires NumPy and Pillow. Metrics measure this supplied scene only, not
perceptual equivalence or generalization to other images.
"""
import json
from pathlib import Path
import sys
import numpy as np
from PIL import Image

folder = Path(sys.argv[1])
images = {name: np.asarray(Image.open(folder / f'{name}.png').convert('RGB'), dtype=np.float32)
          for name in ('native', 'previous', 'corrected')}
reference = images['native']
if not all(image.shape == reference.shape for image in images.values()):
    raise SystemExit('Inputs must have matching dimensions and orientation')
luma = reference @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
report = {'scope': 'One aligned scene in 8-bit sRGB; this is not a percentage similarity or a new-scene validation.',
          'dimensions': [reference.shape[1], reference.shape[0]], 'images': {}}
for name, value in images.items():
    delta = np.abs(value - reference)
    pixel_error = delta.mean(axis=2)
    stats = {'mean_absolute_rgb_error': float(delta.mean()),
             'p95_pixel_rgb_error': float(np.percentile(pixel_error, 95)),
             'near_black_percent': float(np.mean(value.max(axis=2) <= 3) * 100),
             'clipped_channel_percent': float(np.mean(value.max(axis=2) >= 254) * 100),
             'dark_region_error': float(pixel_error[luma < 40].mean()),
             'bright_region_error': float(pixel_error[luma > 180].mean())}
    report['images'][name] = stats
    if name != 'native':
        Image.fromarray(np.uint8(np.clip(delta * 4, 0, 255))).save(folder / f'{name}-difference.png')
(folder / 'metrics.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
