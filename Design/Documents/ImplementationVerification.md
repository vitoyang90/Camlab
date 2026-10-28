# 本次實作與驗證

本文件提及的介面圖片集中於 [Design/Images](../Images/)；工具指令以專案根目錄為執行位置。

日期：2026-10-11。

## 區域調色與 App 內編輯恢復（2026-10-18）

- 預設恢復 App 內配方預覽、拍攝套用及匯入編輯。`PhotoWorkflowPreferences` 將先前原生預設遷移一次，之後保留使用者選擇；原生流程仍是設定中的備用功能。
- 新增 `RecipeColorPipeline`，由 `RecipeAdjustment.applying` 共用於預覽、編輯、完整尺寸輸出。增艷／陰影／亮部以感知亮度遮罩混合調整；遮罩採 80% 像素亮度與 20% 鄰域亮度，鄰域半徑按照片短邊縮放並延伸邊緣。這是自有近似，不是 Apple 的局部直方圖演算法。
- 增艷不再隱式增加飽和度。色溫在感知 RGB 中偏移且保護純黑；正向飽和度採較溫和映射，−100 仍完整去色。對比使用有界響應，保留端點與全範圍單調性。清晰度、銳利度、雜點、暈邊沿用既有共用流程，未宣稱分別對齊原生。
- 使用者的原圖 `IMG_9197 2.HEIC`、原生參考 `IMG_9197.HEIC`，依曝光 +15、增艷 +25、陰影 −30、對比 +15、飽和度 +25、色溫 −30、銳利度 +10、暈邊 +10，經實際 `PhotoProcessor` 輸出 5712 × 4284 JPEG。使用者照片未加入儲存庫。
- `Tools/Calibration/render_recipe_comparison.py` 編譯 App 目前處理程式重現輸出，`Tools/Calibration/measure_recipe_comparison.py` 對齊 sRGB 1600 × 1200 PNG 測量。對照的「上一版」為已修正壓黑的上一版，並非最早的 `CamlabOriginal.jpg`。

| 同一張夜景的測量 | 上一版 | 區域調色新版 |
| --- | ---: | ---: |
| RGB 平均絕對誤差（0–255） | 8.9121 | 7.9620 |
| 像素平均誤差的第 95 百分位 | 22.3333 | 18.6667 |
| 原生暗部區域平均誤差 | 7.2541 | 7.1443 |
| 原生亮部區域平均誤差 | 9.6258 | 8.5002 |
| 至少一通道接近飽和的像素比例 | 3.4739% | 2.8918% |

平均誤差降低約 10.7%，不等於相似度提高 10.7%，也不是跨場景驗證。天空藍色、路面色彩與亮部仍與原生不同；原生飽和像素比例為 1.3219%。只持有一組合併調整參考，不能唯一確定各滑桿映射。白天、人像、逆光及單項調整需要額外原圖／原生結果。未測量真機預覽 FPS、耗電或 HDR 顯示一致性。

驗證：iPhone 17／iOS 26.5 模擬器，29 項影像／配方／工作流程單元測試及 2 項編輯 UI 測試最終通過。初次執行 30 通過、1 失敗，失敗源於測試夾具未延伸邊緣就縮放，造成透明像素混入；修正夾具並另檢查原尺寸不透明邊緣後，6 項區域測試全部通過。未修改產品處理來放寬測試。

- 首輪結果：`/tmp/CamlabRegionalTests.xcresult`
- 區域測試複驗：`/tmp/CamlabRegionalScaleRetest.xcresult`
- 比較成品：`/Users/vitoyang/.codex/visualizations/2026/10/17/01a14945-fb90-7d40-a98b-1fa6c1667e1e/CamlabRegionalComparison/comparison.html`
- Apple 背景資料：[Photos Technical Brief, September 2019](https://www.apple.com/id/privacy/docs/Photos_Tech_Brief_Sept_2019.pdf)。此文件僅提供局部調整背景，不提供可複製的 slider 映射。

## 過場動畫與相簿匯入編輯頁（2026-10-17）

- 調整面板展開／收合、調色／拍攝切換、數字鍵盤、配方選單加入短過場；構圖輔助線和選取狀態淡化。遵循系統減少動態效果設定，動畫只由介面狀態觸發。
- 相簿匯入測試重現編輯頁停在畫面下半部的異常。改由獨立 sheet 管理系統選圖器，以 onDismiss 作為開啟全螢幕編輯頁的界線，同時保留照片讀取完成前後的銜接。
- 編輯頁照片有明確的可用邊界，頂部完成與底部儲存／分享固定；調整內容可捲動。配方改用獨立選單面板，原圖比較使用淡化。
- 直向輸入時增加控制區高度；橫向原圖比較移至頂部，將側欄高度留給數字鍵盤。
- 新增從系統相簿選圖進入編輯頁的 UI 測試，檢查橫直向照片／控制區不重疊、固定按鈕可點擊、鍵盤末排與取消輸入在可視範圍內，以及配方選擇、原圖比較和返回相機。
- iPhone 17／iOS 26.5 模擬器：8 項 UI 測試全部通過；最後鍵盤高度調整後，重新執行相簿匯入編輯測試亦通過，包含末排所有按鍵及取消輸入的可視範圍檢查。git diff --check 通過。未執行真機測試。
- 完整 UI 結果：`/private/tmp/Camlab-motion-build/Logs/Test/Test-Camlab-2026.10.17_17-43-05-+0800.xcresult`；最後編輯頁結果：`/private/tmp/Camlab-motion-build/Logs/Test/Test-Camlab-2026.10.17_17-49-19-+0800.xcresult`。


## 控制區視覺與留白修正（2026-10-13）

- 直向工具列獨立放在取景器上方，取景器維持 3:4 比例，底部調整與快門整合成圓角面板。收合時顯示可捲動的配方快捷列。
- 依使用者補充，橫向控制面板保留滿高；中間使用可捲動的調色／拍攝參數列表，下方固定數值與滑桿，避免大塊空白。
- 橫向數字鍵盤按可用高度配置按鍵；整數輸入、即時預覽、快門可見性保持。
- 強化選取狀態、按鈕形狀與面板細框；參數列全寬皆可點選。
- 新增檢查直向取景器上下留白、橫向面板高度，以及捲動後切換參數的 UI 驗證。
- 初次平行測試遇到模擬器分身啟動錯誤，後續改用單一模擬器。捲動區的測試定位改用 ScrollView，並修正參數列中間空白的點選範圍。
- 最終 iPhone 17（iOS 26.5）模擬器編譯與 6 項 UI 測試通過，0 失敗；包含捲動後選取黑點參數、配方保存／重啟，以及橫向數字輸入。git diff --check 通過。
- 更新 CameraPortraitCurrent.png、CameraPortraitCollapsed.png、CameraLandscapeCurrent.png，新增 CameraLandscapeKeypad.png；皆為本次實際 App 截圖。模擬器沒有相機，保留真實連線提示。

本次結果：`/private/tmp/Camlab-build/Logs/Test/Test-Camlab-2026.10.13_02-22-37-+0800.xcresult`。本次僅修改介面，未重跑相簿與影像處理測試，亦未進行真機拍攝驗證。

## UI 對齊修正（2026-10-12）

使用者指出先前實作的按鈕位置與控制區沒有對齊互動草圖，本次修正主操作列順序、取景器工具位置、橫向窄列與面板背景。

- 主操作列依序為調整、快門、鏡頭；相簿入口改在取景器左下。
- 橫向控制區為 140–164 點，數字鍵盤為 164–184 點，面板背景占滿可用高度；參數名稱與數值分行。
- 直向控制區使用完整寬度底部面板。
- 新增取景原圖比較，調色數值變動或切換配方時返回效果預覽。
- 6 項 UI 測試通過，包含新增的主操作位置與面板寬度驗證。最後面板背景修正後再執行位置驗證通過。
- iPhone 裝置目標編譯通過，git diff --check 通過。
- 實際 App 截圖保存為 CameraPortraitCurrent.png、CameraLandscapeCurrent.png、CameraPortraitCollapsed.png。截圖由 XCUIScreen 擷取完整畫面並依介面方向輸出，非互動草圖；模擬器沒有相機，因此保留真實的無相機提示。

最後位置驗證結果：`/private/tmp/Camlab-build/Logs/Test/Test-Camlab-2026.10.12_01-00-55-+0800.xcresult`。

## 已加入

- 11 項整數調色控制，預覽與成品共用處理流程。
- 配方持久保存、原色、更新、另存、改名、刪除；重啟與切換捨棄未保存的微調。
- 直向底部控制區、橫向側邊窄列、可收合控制與畫面內數字鍵盤。
- 10× 上限及鏡頭能力限制、即時硬體參數與點選對焦座標換算。
- 裝置感測水平線及獨立九宮格開關。
- 拍攝後自動寫入系統相簿，使用同一 asset 保留原圖、成品與調整資料。
- 匯入與拍後編輯、原圖比較、完整尺寸分享。
- 儲存失敗暫留與重試；寫入成功後清理照片暫存。原圖在成品處理前先保存，避免處理失敗就遺失拍攝資料。
- 即時場景／構圖建議記入 PendingFeatures.md，待定，未實作。

## 已執行的驗證

環境：Xcode 26.6、iPhone 17 模擬器（iOS 26.5）。最低部署版本設定為 iOS 26.0。

- 模擬器編譯通過。
- generic iOS 實體裝置目標編譯通過，未進行裝置簽署或安裝。
- Swift Testing：40 個測試、7 個 suite 通過，包含原有相機測試及新增配方、調色像素、水平幾何、點選座標與暫存測試。
- XCTest UI：5 個測試通過，涵蓋整數鍵盤、配方保存／重啟、橫向大幅預覽、水平線／九宮格／倍率入口及模擬器缺少相機的狀態。
- XCTest 相簿整合：1 個測試通過，使用測試 PNG 原圖建立相簿 asset，讀回原圖與配方，再修改同一 asset，確認原圖內容不變、配方更新且暫存清除。執行期間完成模擬器的系統相簿授權與測試樣本清理確認。
- 最後的 XCTest 結果摘要：6 個測試通過、0 失敗、0 跳過。
- git diff --check 通過。

最後 XCTest 結果：`/private/tmp/Camlab-build/Logs/Test/Test-Camlab-2026.10.11_17-16-10-+0800.xcresult`。

## 2026-10-17 翻轉、倍率與圖庫調整

- 翻轉按鈕改為單擊切換前後相機；同側實體鏡頭不再放進翻轉選單。
- 後置優先採用三鏡頭、雙廣角、雙鏡頭虛擬裝置，再回退至單廣角。倍率透過系統顯示倍率係數換算，硬體切換點加入常用倍率列，保留 10× 上限。
- 圖庫移至快門左側（橫向為上方），顯示 48 點縮圖或照片圖示與文字；調整參數和相機設定各自保有入口。
- iPhone 17／iOS 26.5 模擬器編譯通過，6 項 CameraZoomScaleTests 與 2 項介面測試通過。已查看直向收合、直向調色與橫向調色的測試截圖，更新 Design 中對應的實際介面圖。
- 測試結果：`/tmp/CamlabControlsTests.xcresult`。本次未重新執行完整相簿整合測試；模擬器無法驗證實體鏡頭切換、超廣角畫面與切換期間的預覽連續性。
- 實作參考：[Apple 的多鏡頭切換倍率 API](https://developer.apple.com/documentation/avfoundation/avcapturedevice/virtualdeviceswitchovervideozoomfactors) 與本機 SDK 的 `displayVideoZoomFactorMultiplier` 說明。

## 2026-10-17 補齊手動調整項目

- 新增銳利度、清晰度、降低雜點與暈邊，與原有項目合計 15 項。前三項為 0–100，暈邊為 −100–100；滑桿、標示、輸入驗證與鍵盤正負號皆依參數範圍處理。
- 降噪先於細節增強；清晰度以較大半徑局部對比處理，銳利度使用較小半徑亮度銳化；兩者半徑依影像短邊縮放。空間濾鏡延展邊緣後裁回原尺寸，避免黑邊。暈邊使用依畫面中心與尺寸計算的漸層遮罩，正值壓暗、負值提亮。
- 共用 `RecipeAdjustment.applying`，涵蓋即時預覽、拍照輸出、照片編輯、分享。沿用字典式配方格式；舊檔缺少新鍵時為 0，既有數值不變。
- 已驗證新增參數範圍、舊配方讀取與重啟、銳化／降噪對細節能量的影響、清晰度與銳利度的差異、暈邊方向與中心保留、非零影像原點、輸出尺寸與不透明邊緣，以及相簿同一 asset 的原圖與新調整資料往返。
- iPhone 17／iOS 26.5 編譯與 22 項選定測試通過：19 項 Swift Testing、1 項相簿整合、2 項 UI 測試。結果：`/tmp/CamlabDetailTests2.xcresult`。已查看橫直向截圖，保存為 `CameraDefinitionPortrait.png`、`CameraDefinitionLandscape.png`；整合測試建立的圖片已經使用者同意清理。
- 項目對照：[Apple Photos 技術說明，第 12 頁](https://www.apple.com/id/privacy/docs/Photos_Tech_Brief_Sept_2019.pdf)。這裡補齊的是手動調整參數；效果使用 Camlab 的 Core Image 映射，相同數值尚未與 Apple 私有演算法完成視覺校準。

## 2026-10-17 夜景對比壓黑修正

- 使用者提供同一場景的未調色 HEIC、iPhone「照片」調整結果與 Camlab 舊版 JPEG。配方：曝光 +15、增艷 +25、陰影 −30、對比 +15、飽和度 +25、色溫 −30、銳利度 +10、暈邊 +10，其餘 0。
- 根因驗證：原本 `CIColorControls` 對比在預設線性工作色域以 0.5 為中心運算；僅 +15 就會將 sRGB 灰階 16、32、48 壓成 0。現在使用 `CIToneCurve` 的感知曲線，固定黑白端點，以單調曲線增加／降低對比。亮度與飽和度先轉成感知 sRGB 訊號，處理後再轉回線性光供後續濾鏡使用。
- 暫存比較過線性對比、感知空間線性對比、保留端點曲線，以及標準色溫濾鏡。感知空間中的線性對比仍造成黑位截斷；標準色溫濾鏡未改善這個案例的整體像素誤差，未採用。
- 正式驗證直接編譯 App 的 `RecipeAdjustment`、`StyleAdjustment`、`PhotoProcessor`，從完整 HEIC 輸出 5712 × 4284 JPEG，再以相同 ColorSync sRGB 轉換和長邊 1600 縮圖比較。`max(R,G,B) <= 3/255` 的近黑像素占比：原生 1.64%、使用者提供的舊版 29.85%、修正後 2.18%。此指標只證明嚴重暗部截斷改善，不代表原生外觀完全一致；原生藍色夜空、亮部色彩仍有差異。
- 新增 4 項回歸測試：低灰階分離、正負對比範圍內單調性／端點／不透明度、飽和度保留中性灰、完整夜景配方保留陰影層次。連同配方持久化、細節濾鏡與照片輸出測試，共 23 項通過（iPhone 17／iOS 26.5），結果 `/tmp/CamlabToneTests.xcresult`。
- `Tools/Calibration/render_recipe_comparison.py` 可從外部三個圖片路徑重跑正式輸出並產生比較頁面，照片不納入程式庫。macOS 沙盒可能使 HEIC／Core Image 輸出全黑；此環境的校準已取得許可在沙盒外執行。範例：`python3 Tools/Calibration/render_recipe_comparison.py ORIGINAL.heic NATIVE.heic PREVIOUS.jpg /tmp/CamlabNightComparison`。
- 配方檔格式及數值不變，舊配方重新渲染採用修正流程；不自動修改已保存的成品。
- 參考：[Apple Core Image 工作色域](https://developer.apple.com/documentation/coreimage/cicontextoption/workingcolorspace)、[Apple 濾鏡文件的 CIToneCurve 感知 gamma-2 說明](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Reference/CoreImageFilterReference/index.html)。

## 2026-10-18 原生照片調整流程

- 使用者接受由原生「照片」完成編輯的流程。新增預設開啟、可持續保存的原生流程設定；近似模式保留於設定中。原生模式取景顯示原色，配方只作為手動清單，拍照後自動進入原生流程畫面。
- 原生拍攝暫存保留原始資料，PhotoKit 只建立原圖 asset，不提交 Camlab 調整；待儲存資料記錄模式與清單，重試、重啟與舊版資料解碼均保持正確模式。舊版待儲存編輯仍走原本流程。
- 新增 `PhotoLibrarySaver.loadCurrent`，以 `PHImageRequestOptions.version = .current` 取得最大尺寸目前版本，涵蓋既有 Camlab 照片及外部編輯。回到前景重新讀取同一 asset，也提供手動重新讀取；選圖器專屬存取會提示重新選擇，不假裝具備持續讀取權限。
- `NativePhotoContent` 依影像實際格式產生分享副檔名，直接寫入收到的 Data，不經 `PhotoProcessor.render` 或重新 JPEG 編碼。失敗重讀停用分享直到成功，分享暫存於完成／關閉後清理。
- 4 項新單元測試通過：分享 bytes／格式、原生暫存不套配方及模式恢復、目前版本更新與失敗後防止分享舊資料、picker-only 行為。1 項 PhotoKit 模擬器整合測試通過：保存原圖資源與輸入完全相同、未附 Camlab 調整、提交外部編輯後讀得新畫面、分享資料與 Photos 回傳完全相同。2 項 UI 測試通過：原生流程與保留的舊編輯器皆能匯入、操作及橫直向布局。結果 `/tmp/CamlabNativeTests2.xcresult`。精簡說明後另通過最終 UI 驗證 `/tmp/CamlabNativeLayoutTests.xcresult`，已檢視並保存 `NativePhotoPortrait.png` 與 `NativePhotoLandscape.png`。
- 12 項既有配方／照片流程測試在前次執行通過（`/tmp/CamlabNativeTests.xcresult`）；該次另外 3 項失敗已在上述結果修正。總共 19 項相關測試驗證通過。原本失敗分別為 current representation 的中繼資料更新、啟動參數布林值讀取、UI 測試使用錯誤的 accessibility 類型；測試改為分別核對原圖 resource 和目前版本的 byte 保留，不混為同一檔案。
- 另以使用者提供的原生 HEIC 執行正式 `NativePhotoContent` 分享邏輯：3,976,226 bytes 全部一致，副檔名保留 heic。此測試不讀寫原檔、不對照片重編碼。
- 相簿整合測試只操作新建的模擬器純色 fixture，不修改或刪除既有照片；測試 fixture 保留在模擬器。尚未在實機完成手動切換 Photos、編輯與返回，以及 HDR 顯示、iCloud、受限權限的端到端驗證。
- 參考：[Apple requestImageDataAndOrientation 目前版本行為](https://developer.apple.com/documentation/photos/phimagemanager/requestimagedataandorientation(for:options:resulthandler:))。不使用未公開的 Photos 深連結或原生參數注入介面。

## 尚需真機驗證

- 相機啟動與即時預覽效能、完整尺寸照片處理、前後鏡頭與各鏡頭變焦範圍。
- 點對焦、水平線方向、橫直向構圖與照片方向。
- 真機相簿完整／受限／拒絕權限、iCloud 原圖下載、背景中斷與重試。
- iOS 26.0 真機相容性；目前是以 26.0 最低目標編譯，執行測試使用 26.5 模擬器。
- Camlab 的整數調色映射與 iPhone「照片」的視覺對照。現在是 Core Image 近似處理，未宣稱相同數值能完全複製 Apple 的私有演算法。
