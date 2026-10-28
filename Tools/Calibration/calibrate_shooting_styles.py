#!/usr/bin/env python3
"""Reproducible style review using the shipping Core Image renderer (macOS).

fetch: download the attributed public samples and normalize to 1200px sRGB PNG.
render LABEL: render frozen before/round1/round2/round3 or current after built-ins for each sample.
report: compare before/after pixels and create offline contact sheets + HTML.
check: enforce review guardrails for this six-scene corpus (not universal quality).
Requires Pillow, NumPy, Xcode Swift; does not change any camera presets itself.
"""
import hashlib
import html
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from PIL import Image, ImageCms, ImageOps, ImageDraw
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'Design/StyleCalibration'
SAMPLES = [
    ('portrait', '自然光人像', '6/6f/Portrait_with_natural_light_%28Creative_Commons%29.jpg',
     'Portrait_with_natural_light_(Creative_Commons).jpg', 'Wendelin Jacober; model: Sheila Rizzo', 'CC BY 2.0', 'https://creativecommons.org/licenses/by/2.0/'),
    ('portrait_studio', '棚燈人像', '0/04/Mae_Jemison_-_Official_portrait_of_1987_astronaut_candidate.jpg',
     'Mae_Jemison_-_Official_portrait_of_1987_astronaut_candidate.jpg', 'NASA, S87-45893', 'Public domain (US federal government)', 'https://commons.wikimedia.org/wiki/Template:PD-USGov-NASA'),
    ('daylight', '湖景與天空', 'c/c3/Lake_Louise_17092005_1.jpg', 'Lake_Louise_17092005_1.jpg',
     'Gorgo / Wikimedia Commons', 'Public domain', 'https://creativecommons.org/publicdomain/mark/1.0/'),
    ('interior', '咖啡館室內', 'e/e3/Balat_Antique_Cafe_Interior_Traditional_Decor_Istanbul.jpg',
     'Balat_Antique_Cafe_Interior_Traditional_Decor_Istanbul.jpg', 'Tolga Bakı', 'CC0 1.0', 'https://creativecommons.org/publicdomain/zero/1.0/'),
    ('night', '台北夜間街景', 'f/f5/Traffic_on_Nanjing_West_Road_in_Taipei_at_night.jpg',
     'Traffic_on_Nanjing_West_Road_in_Taipei_at_night.jpg', 'Benlisquare', 'CC BY-SA 4.0', 'https://creativecommons.org/licenses/by-sa/4.0/'),
    ('sunset', '海灘夕陽', 'd/d1/Beach_at_Sunset_-_50134955282.jpg', 'Beach_at_Sunset_-_50134955282.jpg',
     'Alabama Extension / Bruce Dupree', 'CC0 1.0', 'https://creativecommons.org/publicdomain/zero/1.0/'),
]

def fetch():
    (OUT / 'sources').mkdir(parents=True, exist_ok=True)
    manifest = []
    for key, title, remote, page, author, license_name, license_url in SAMPLES:
        url = 'https://upload.wikimedia.org/wikipedia/commons/' + remote
        with tempfile.TemporaryDirectory(prefix='CamlabSample-') as temp:
            path = Path(temp) / 'source.jpg'
            subprocess.run(['curl', '-L', '--fail', '--retry', '2', '--max-time', '90', url, '-o', str(path)], check=True)
            raw = path.read_bytes()
            image = ImageOps.exif_transpose(Image.open(io.BytesIO(raw)))
            profile = image.info.get('icc_profile')
            image = image.convert('RGB')
            if profile:
                image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(profile)),
                                                 ImageCms.createProfile('sRGB'), outputMode='RGB')
            original_size = image.size
            image.thumbnail((1200, 1200), Image.Resampling.LANCZOS)
            image.save(OUT / 'sources' / (key + '.png'), icc_profile=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes())
            manifest.append(dict(id=key, title=title, url=url,
                page='https://commons.wikimedia.org/wiki/File:' + page,
                author=author, license=license_name, license_url=license_url,
                original_sha256=hashlib.sha256(raw).hexdigest(), original_size=original_size,
                changes='EXIF orientation normalized; converted/assumed sRGB; resized to max 1200px. Rendered variants apply Camlab color recipes. Night derivatives retain CC BY-SA 4.0.'))
    (OUT / 'sources.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')

def render(label):
    if label not in ('before', 'round1', 'round2', 'round3', 'after'):
        raise SystemExit('Label must be before, round1, round2, round3 or after')
    destination = OUT / label
    destination.mkdir(parents=True, exist_ok=True)
    def source_file(filename):
        frozen = destination / filename
        if label != 'after':
            if not frozen.exists():
                raise SystemExit(f'Missing frozen source: {frozen}')
            return frozen
        category = 'Imaging' if filename in ('PhotoProcessor.swift', 'RecipeColorPipeline.swift') else 'Recipes'
        return ROOT / 'Camlab' / category / filename
    recipe = source_file('PhotoRecipe.swift').read_text().split('@MainActor @Observable')[0]
    style = source_file('PhotoStyle.swift').read_text().split('nonisolated struct StyleDraft:')[0]
    source = '\n'.join([recipe, style] + [source_file(f).read_text() for f in
        ['RecipeColorPipeline.swift', 'PhotoProcessor.swift', 'ShootingStyle.swift']]).replace('nonisolated ', '')
    source += r'''
struct CameraFailure: Error { let message: String; init(_ message: String) { self.message = message } }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(ShootingStyle.recipes).write(to: output.appendingPathComponent("recipes.json"))
let processor = PhotoProcessor()
for file in try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil) where file.pathExtension == "png" {
    let key = file.deletingPathExtension().lastPathComponent
    let data = try Data(contentsOf: file)
    for preset in ShootingStyle.allCases {
        try autoreleasepool {
            let rendered = try processor.render(data, style: StyleAdjustment(recipe: preset.adjustment, recipeName: preset.name))
            try rendered.data.write(to: output.appendingPathComponent("\(key)-\(preset.rawValue).jpg"))
        }
    }
    print("Rendered", key)
}
'''
    with tempfile.TemporaryDirectory(prefix='CamlabStyles-') as temp:
        main = Path(temp) / 'main.swift'
        main.write_text(source)
        binary = Path(temp) / 'render'
        env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
        subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', '/private/tmp/CamlabStyleModuleCache',
                        str(main), '-o', str(binary)], env=env, check=True)
        subprocess.run([str(binary), str(OUT / 'sources'), str(destination)], check=True)
    for filename in ['ShootingStyle.swift', 'PhotoRecipe.swift', 'PhotoStyle.swift', 'RecipeColorPipeline.swift', 'PhotoProcessor.swift']:
        (destination / filename).write_bytes(source_file(filename).read_bytes())

def rgb(path):
    return np.asarray(Image.open(path).convert('RGB'), dtype=np.float32)

def stats(image, original):
    lum = image @ np.array([.2126, .7152, .0722])
    old_lum = original @ np.array([.2126, .7152, .0722])
    shadow = (old_lum > 8) & (old_lum < 64)
    newly_clipped = (image >= 254) & (original < 250)
    return dict(mean_luma=float(lum.mean()),
                newly_clipped_channel_percent=float(newly_clipped.mean() * 100),
                newly_crushed_pixel_percent=float(((image.max(2) <= 3) & (old_lum > 8)).mean() * 100),
                shadow_mean=float(lum[shadow].mean()) if shadow.any() else None,
                rgb_change=float(np.abs(image - original).mean()))

def contact_sheets(phase):
    manifest = json.loads((OUT / 'sources.json').read_text())
    # Review contact sheets: original + 12 styles, no photo cropping.
    if phase in ['before', 'round1', 'round2', 'round3', 'after']:
        for sample in manifest:
            key = sample['id']
            sheet = Image.new('RGB', (1400, 4 * 255), '#171717')
            draw = ImageDraw.Draw(sheet)
            paths = [OUT / 'sources' / (key + '.png')] + [OUT / phase / f'{key}-{i}.jpg' for i in range(1, 13)]
            for index, path in enumerate(paths):
                col, row = index % 4, index // 4
                image = Image.open(path).convert('RGB')
                image.thumbnail((340, 220))
                x, y = col * 350, row * 255
                sheet.paste(image, (x + (350 - image.width)//2, y + 25 + (220-image.height)//2))
                draw.text((x + 8, y + 6), 'Original' if index == 0 else f'{index:02d}', fill='white')
            sheet.save(OUT / f'{key}-{phase}-sheet.jpg', quality=92)

def report():
    recipes = json.loads((OUT / 'after/recipes.json').read_text())
    phases = ['before', 'round1', 'round2', 'round3', 'after']
    versions = {phase: json.loads((OUT / phase / 'recipes.json').read_text()) for phase in phases}
    manifest = json.loads((OUT / 'sources.json').read_text())
    results = []
    # Full originals and outputs are viewable without cropping in the HTML.
    for sample in manifest:
        key = sample['id']
        original = rgb(OUT / 'sources' / (key + '.png'))
        for index, recipe in enumerate(recipes, 1):
            for phase in phases:
                value = rgb(OUT / phase / f'{key}-{index}.jpg')
                results.append(dict(scene=key, style=recipe['name'], phase=phase, **stats(value, original)))
    (OUT / 'metrics.json').write_text(json.dumps(results, indent=2, ensure_ascii=False) + '\n')
    for phase in phases: contact_sheets(phase)
    payload = json.dumps(dict(samples=manifest, recipes=recipes, versions=versions, metrics=results), ensure_ascii=False).replace('</', '<\\/')
    template = (ROOT / 'Tools/Calibration/style_calibration.html').read_text()
    (OUT / 'comparison.html').write_text(template.replace('/*PAYLOAD*/null', payload))

def check():
    rows = json.loads((OUT / 'metrics.json').read_text())
    after = [r for r in rows if r['phase'] == 'after']
    assert len(after) == len(SAMPLES) * 12
    for row in after:
        assert row['newly_clipped_channel_percent'] < 0.1, row
        # Dark, contrast-led looks may deepen shadows; flag large losses.
        assert row['newly_crushed_pixel_percent'] < 0.5, row
        for phase in ['before', 'round1', 'round2', 'round3']:
            baseline = next(r for r in rows if r['phase'] == phase and r['scene'] == row['scene'] and r['style'] == row['style'])
            # Allow 0.01 percentage points for encoding and rounding changes.
            assert row['newly_clipped_channel_percent'] <= baseline['newly_clipped_channel_percent'] + 0.01, (phase, row)
            assert row['newly_crushed_pixel_percent'] <= baseline['newly_crushed_pixel_percent'] + 0.01, (phase, row)
    print('PASS: 72 scene/style outputs meet corpus clipping and shadow guardrails.')

if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    if sys.argv[1:] == ['fetch']: fetch()
    elif sys.argv[1:2] == ['render'] and len(sys.argv) == 3: render(sys.argv[2])
    elif sys.argv[1:2] == ['sheets'] and len(sys.argv) == 3: contact_sheets(sys.argv[2])
    elif sys.argv[1:] == ['report']: report()
    elif sys.argv[1:] == ['check']: check()
    else: raise SystemExit(__doc__)
