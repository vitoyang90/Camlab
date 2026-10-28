#!/usr/bin/env python3
"""Repeatable synthetic-noise review through frozen/current shipping Swift.

Noise added here is a controlled stress test, not a camera sensor/ISO model.
Photo sources and derivative licenses remain in StyleCalibration/sources.json.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
CAL = ROOT / 'Design/StyleCalibration'
OUT = CAL / 'shadow-noise'
FILES = ['PhotoRecipe.swift', 'PhotoStyle.swift', 'RecipeColorPipeline.swift', 'PhotoProcessor.swift', 'ShootingStyle.swift']


def fixtures():
    OUT.mkdir(exist_ok=True)
    y, x = np.mgrid[:512, :512]
    base = np.where(x < 256, 0.12, 0.26) + np.where(y > 256, 0.02 * np.sin(x * np.pi / 4), 0)
    chart = np.repeat(base[:, :, None], 3, axis=2)
    rng = np.random.default_rng(20261028)
    for key in ['chart', 'portrait', 'night']:
        clean = chart if key == 'chart' else np.asarray(Image.open(CAL / 'sources' / f'{key}.png').convert('RGB'), dtype=float) / 255
        lum = clean @ np.array([.2126, .7152, .0722])
        t = np.clip((lum - .18) / (.60 - .18), 0, 1)
        dark = (1 - t*t*(3-2*t))[:, :, None]
        # Independent channel noise plus shared luminance noise, scaled by darkness.
        noise = rng.normal(0, 4/255, clean.shape) + rng.normal(0, 3/255, (*clean.shape[:2], 1))
        noisy = np.clip(clean + noise * dark, 0, 1)
        for label, data in [('clean', clean), ('noisy', noisy)]:
            Image.fromarray(np.round(data * 255).astype(np.uint8)).save(OUT / f'{key}-{label}.png')


def render(phase):
    folder = CAL / phase
    source = '\n'.join([
        (folder / 'PhotoRecipe.swift').read_text().split('@MainActor @Observable')[0],
        (folder / 'PhotoStyle.swift').read_text().split('nonisolated struct StyleDraft:')[0],
        *[(folder / f).read_text() for f in FILES[2:]],
    ]).replace('nonisolated ', '')
    source += r'''
struct CameraFailure: Error { let message: String; init(_ message: String) { self.message = message } }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let phase = CommandLine.arguments[2]
let processor = PhotoProcessor()
for key in ["chart", "portrait", "night"] {
    var recipe = ShootingStyle.cinema.adjustment
    if key == "chart" { recipe = RecipeAdjustment(); recipe[.shadows] = 60 }
    for kind in ["clean", "noisy"] {
        let data = try Data(contentsOf: root.appendingPathComponent("\(key)-\(kind).png"))
        let rendered = try processor.render(data, style: StyleAdjustment(recipe: recipe))
        try rendered.data.write(to: root.appendingPathComponent("\(key)-\(phase)-\(kind).jpg"))
    }
}
'''
    with tempfile.TemporaryDirectory(prefix='CamlabShadowNoise-') as temp:
        main = Path(temp) / 'main.swift'; main.write_text(source)
        binary = Path(temp) / 'render'
        subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', '/private/tmp/CamlabStyleModuleCache', str(main), '-o', str(binary)],
                       env=dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'), check=True)
        subprocess.run([str(binary), str(OUT), phase], check=True)


def report():
    metrics = []
    sheet = Image.new('RGB', (1600, 3 * 340 + 100), '#171717')
    draw = ImageDraw.Draw(sheet)
    for row, key in enumerate(['chart', 'portrait', 'night']):
        reference = np.asarray(Image.open(OUT / f'{key}-clean.png').convert('RGB'), dtype=float)
        lum = reference @ np.array([.2126, .7152, .0722])
        mask = (lum > 8) & (lum < 70)
        for phase in ['round3', 'after']:
            clean = np.asarray(Image.open(OUT / f'{key}-{phase}-clean.jpg').convert('RGB'), dtype=float)
            noisy = np.asarray(Image.open(OUT / f'{key}-{phase}-noisy.jpg').convert('RGB'), dtype=float)
            delta = noisy - clean
            luma = delta @ np.array([.2126, .7152, .0722])
            chroma = delta - luma[:, :, None]
            metrics.append(dict(scene=key, phase=phase,
                                luma_rmse=float(np.sqrt((luma[mask]**2).mean())),
                                chroma_rmse=float(np.sqrt((chroma[mask]**2).mean()))))
        paths = [(f'{key}-after-clean.jpg', 'Clean reference / current'),
                 (f'{key}-noisy.png', 'Synthetic noisy input'),
                 (f'{key}-round3-noisy.jpg', 'Round 3'), (f'{key}-after-noisy.jpg', 'Round 4')]
        for col, (filename, label) in enumerate(paths):
            image = Image.open(OUT / filename).convert('RGB')
            image.thumbnail((390, 300))
            sheet.paste(image, (col*400 + (400-image.width)//2, row*340+30))
            draw.text((col*400+8, row*340+6), f'{key}: {label}', fill='white')
    credits = [
        'Synthetic noise stress test, not a real sensor/ISO sample. Images resized and processed with Camlab. Composite: CC BY-SA 4.0.',
        'Portrait: Wendelin Jacober; model Sheila Rizzo (CC BY 2.0). Night: Benlisquare (CC BY-SA 4.0). Full provenance: ../sources.json',
        'https://commons.wikimedia.org/wiki/File:Portrait_with_natural_light_(Creative_Commons).jpg',
        'https://commons.wikimedia.org/wiki/File:Traffic_on_Nanjing_West_Road_in_Taipei_at_night.jpg | https://creativecommons.org/licenses/by-sa/4.0/'
    ]
    for index, line in enumerate(credits):
        draw.text((12, 1024 + index*22), line, fill='#ddd')
    sheet.save(OUT / 'comparison.jpg', quality=95)
    (OUT / 'metrics.json').write_text(json.dumps(metrics, indent=2) + '\n')
    for key in ['chart', 'portrait', 'night']:
        old, new = [next(r for r in metrics if r['scene'] == key and r['phase'] == p) for p in ['round3', 'after']]
        assert new['chroma_rmse'] < old['chroma_rmse'] * .95, (key, old, new)
        assert new['luma_rmse'] < old['luma_rmse'] * 1.02, (key, old, new)
        print(key, 'chroma RMSE', round(old['chroma_rmse'], 3), '->', round(new['chroma_rmse'], 3),
              'luma RMSE', round(old['luma_rmse'], 3), '->', round(new['luma_rmse'], 3))


if __name__ == '__main__':
    fixtures()
    render('round3')
    render('after')
    report()
