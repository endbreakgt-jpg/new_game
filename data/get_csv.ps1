$folderPath = ".\*.csv"  # 例：カレントディレクトリのCSVファイル

Get-ChildItem -Path $folderPath | ForEach-Object {
    $fileName = $_.Name         # ①ファイル名
    
    # ファイルの内容を読み込み
    $content = Get-Content $_.FullName -TotalCount 2  # 最初の2行だけを読み込む

    if ($content.Count -ge 1) {
        $header = $content[0]   # ②ヘッダー行
    } else {
        $header = "ファイルが空です"
    }
    
    if ($content.Count -ge 2) {
        $firstRow = $content[1]  # ③テーブルの1行目 (2行目)
    } else {
        $firstRow = "データ行なし"
    }

    # 結果の出力
    "------------------------------"
    "① ファイル名: $($fileName)"
    "② ヘッダー行: $($header)"
    "③ テーブルの1行目: $($firstRow)"
}
"------------------------------"