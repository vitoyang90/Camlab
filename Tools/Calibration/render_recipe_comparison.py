#!/usr/bin/env python3
"""Render the calibration recipe through the app's actual PhotoProcessor.

Usage: python3 Tools/Calibration/render_recipe_comparison.py ORIGINAL NATIVE_REFERENCE PREVIOUS_OUTPUT OUTPUT_DIR
Inputs stay outside the repository. Requires macOS, Swift and working Core Image access.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
if len(sys.argv) != 5:
    raise SystemExit(__doc__)
original, reference, previous, destination = map(lambda p: Path(p).resolve(), sys.argv[1:])
destination.mkdir(parents=True, exist_ok=True)
# Compile the shipping renderer, not an independently reimplemented algorithm.
recipe = (root / 'Camlab/Recipes/PhotoRecipe.swift').read_text().split('nonisolated struct PhotoRecipe:')[0]
style = (root / 'Camlab/Recipes/PhotoStyle.swift').read_text().split('nonisolated struct StyleDraft:')[0]
processor = (root / 'Camlab/Imaging/PhotoProcessor.swift').read_text()
pipeline = (root / 'Camlab/Imaging/RecipeColorPipeline.swift').read_text()
source = '\n'.join([recipe, pipeline, style, processor]).replace('nonisolated ', '')
source += r'''
struct CameraFailure: Error { let message: String; init(_ message: String) { self.message = message } }
let args = CommandLine.arguments
let folder = URL(fileURLWithPath: args[4], isDirectory: true)
var recipe = RecipeAdjustment()
recipe[.exposure] = 15
recipe[.brilliance] = 25
recipe[.shadows] = -30
recipe[.contrast] = 15
recipe[.saturation] = 25
recipe[.warmth] = -30
recipe[.sharpness] = 10
recipe[.vignette] = 10
let rendered = try PhotoProcessor().render(Data(contentsOf: URL(fileURLWithPath: args[1])),
                                         style: StyleAdjustment(recipe: recipe))
let output = folder.appendingPathComponent("Camlab-corrected.jpg")
try rendered.data.write(to: output)
print("Export:", rendered.width, "x", rendered.height)
'''
with tempfile.TemporaryDirectory(prefix='CamlabCalibration-') as temp:
    script = Path(temp) / 'main.swift'
    script.write_text(source)
    subprocess.run(['/usr/bin/swift', '-module-cache-path', '/tmp/CamlabCalibrationModuleCache', str(script),
                    str(original), str(reference), str(previous), str(destination)], check=True)
    for name, path in [('native', reference), ('previous', previous), ('corrected', destination / 'Camlab-corrected.jpg')]:
        subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', '--matchTo',
                        '/System/Library/ColorSync/Profiles/sRGB Profile.icc', '-Z', '1600', str(path),
                        '--out', str(destination / (name + '.png'))], check=True, capture_output=True)
(destination / 'recipe.json').write_text(json.dumps(dict(exposure=15, brilliance=25, shadows=-30, contrast=15,
                                                         saturation=25, warmth=-30, sharpness=10, vignette=10), indent=2))
(destination / 'comparison.html').write_text('''<!doctype html><meta charset="utf-8"><title>Camlab 夜景比較</title>
<style>body{margin:24px;background:#181818;color:white;font:16px system-ui;line-height:1.6}main{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}img{width:100%}h2{font-size:18px}a{color:#ddd}@media(max-width:800px){main{grid-template-columns:1fr}}</style>
<h1>同一張原圖、同一組夜景數值</h1>
<p>曝光 +15 · 增艷 +25 · 陰影 −30 · 對比 +15 · 飽和度 +25 · 色溫 −30 · 銳利度 +10 · 暈邊 +10</p>
<p>目前只有這一組夜景參考；此頁呈現實際差異，不代表其他場景已與原生一致。點照片可檢查較大影像。</p><main>''' + ''.join(
    f'<section><h2>{title}</h2><a href="{name}.png"><img src="{name}.png"></a></section>'
    for name, title in [('native','iPhone 照片參考'), ('previous','Camlab 上一版'), ('corrected','Camlab 區域調色新版')]) + '</main><p><a href="Camlab-corrected.jpg">完整尺寸新版 JPEG</a> · <a href="metrics.json">誤差測量（執行 measure_recipe_comparison.py 後產生）</a></p>')
print(destination / 'comparison.html')
