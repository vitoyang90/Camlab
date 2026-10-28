# Camlab App Icon

2D 平面光圈圖示，保留暖黃色與深灰色六片光圈葉片、置中構圖及近黑背景。移除原本的立體鏡頭、金屬外圈、反光與厚度，中央改為簡潔深色開口。無文字，外部圓角交由 iOS 套用。

- 工具：內建 imagegen，以原本 App 圖示進行風格轉換。
- 專案圖檔：`Camlab/Assets.xcassets/AppIcon.appiconset/AppIcon.png`。
- 輸出：1024 × 1024 PNG，無透明通道；一般外觀使用此圖，其他外觀由系統處理。
- 生成後以 macOS `sips` 縮放至資產目錄要求的 1024 × 1024。

## 完整生成提示詞

```text
Use case: style-transfer.
Asset type: production iOS app icon for Camlab, square 1024 x 1024.
Input image 1 is the existing app icon, the edit target.
Primary request: Convert this icon into a strictly flat 2D graphic. Preserve its centered camera aperture identity, six broad interlocking blades, alternating warm yellow and charcoal, and near-black background. Simplify the central glass lens into a single flat dark opening. Simplify the perimeter into a clean circular silhouette with no lens hardware rings. The mark occupies approximately 76 percent of the canvas width with balanced margins.
Style: crisp geometric vector-like flat design, bold and minimal, uniform solid fills. Every shape is on the same flat plane. Use warm yellow #FACF4D, charcoal #303030, and near-black #080808 only, with clean antialiased edges. Eliminate ALL 3D depth, gradients, bevels, shadows, lighting, metallic texture, highlights, glass reflections, and dimensional overlaps. Separate blades with clean thin background-colored gaps if needed for legibility.
Background: uniform solid opaque near-black #080808 extending to all four square edges. No rounded outer tile corners; iOS supplies the mask.
Constraints: one finished icon only. No text, no letters, no numerals, no watermark, no mockup, no border around the canvas, no transparency.
```
