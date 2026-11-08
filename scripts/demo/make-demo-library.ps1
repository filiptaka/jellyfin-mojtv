<#
Creates a demo TV library that shows every case of Jellyfin 12's "Recently Added" logic:
a single new episode, a new season of a multi-season show, a new show, and new episodes
across seasons. Episode files are empty; dates come from the file creation time, so the
server must use "Use file creation date" for date added. Posters are generated here.

Writes <Root>\Shows\... and <Root>\watched.txt (episode paths to mark as played).
#>
param([Parameter(Mandatory)] [string] $Root)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$now = Get-Date

# Ages are in hours before now. Watched episodes get marked as played after the scan.
$shows = @(
    @{ Name = 'Night Shift Diaries'; Year = 2025; Colors = '#3a1c71', '#d76d77'; Seasons = @(
        @{ N = 1; Eps = 1..5; Age = 480; Watched = $true }, @{ N = 1; Eps = @(6); Age = 1 }) },
    @{ Name = 'Harbor Lights'; Year = 2024; Colors = '#0f4c75', '#3282b8'; Seasons = @(
        @{ N = 1; Eps = 1..8; Age = 1440; Watched = $true }, @{ N = 2; Eps = 1..8; Age = 720; Watched = $true },
        @{ N = 3; Eps = 1..4; Age = 2 }) },
    @{ Name = 'Orbit Station'; Year = 2023; Colors = '#141e30', '#3a6073'; Seasons = @(
        @{ N = 1; Eps = 1..10; Age = 2160; Watched = $true }, @{ N = 2; Eps = 1..4; Age = 336; Watched = $true },
        @{ N = 2; Eps = @(5); Age = 3 }) },
    @{ Name = 'Copper Creek'; Year = 2026; Colors = '#b24592', '#f15f79'; Seasons = @(
        @{ N = 1; Eps = 1..6; Age = 5 }) },
    @{ Name = 'The Quiet Valley'; Year = 2022; Colors = '#134e5e', '#71b280'; Seasons = @(
        @{ N = 1; Eps = 1..8; Age = 4800; Watched = $true }, @{ N = 2; Eps = 1..9; Age = 2400; Watched = $true },
        @{ N = 2; Eps = @(10); Age = 6 }, @{ N = 3; Eps = @(1); Age = 6 }) },
    @{ Name = 'Lantern Street'; Year = 2025; Colors = '#e65c00', '#f9d423'; Seasons = @(
        @{ N = 1; Eps = 1..5; Age = 960; Watched = $true }, @{ N = 1; Eps = 6..8; Age = 960 },
        @{ N = 2; Eps = 1..3; Age = 8 }) },
    @{ Name = 'Paper Moons'; Year = 2026; Colors = '#232526', '#8e9eab'; Seasons = @(
        @{ N = 1; Eps = @(1); Age = 10 }) },
    @{ Name = 'Frost Line'; Year = 2021; Colors = '#1e3c72', '#a1c4fd'; Seasons = @(
        @{ N = 1; Eps = 1..8; Age = 7200; Watched = $true }, @{ N = 2; Eps = 1..8; Age = 6480; Watched = $true },
        @{ N = 3; Eps = 1..8; Age = 5760; Watched = $true }, @{ N = 4; Eps = @(1); Age = 72 },
        @{ N = 4; Eps = @(2); Age = 12 }) }
)

function New-Poster([string] $Path, [string] $Title, [string] $Footer, [string[]] $Colors) {
    $w = 600; $h = 900
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $c1 = [System.Drawing.ColorTranslator]::FromHtml($Colors[0])
    $c2 = [System.Drawing.ColorTranslator]::FromHtml($Colors[1])
    $g.FillRectangle((New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, $c1, $c2, 70), $rect)
    $glow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40, 255, 255, 255))
    $g.FillEllipse($glow, 120, 120, 360, 360)
    $g.FillEllipse($glow, 190, 190, 220, 220)
    $center = New-Object System.Drawing.StringFormat
    $center.Alignment = 'Center'; $center.LineAlignment = 'Center'
    $titleFont = New-Object System.Drawing.Font 'Segoe UI', 46, ([System.Drawing.FontStyle]::Bold)
    $g.DrawString($Title.ToUpper(), $titleFont, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 30, 470, 540, 250), $center)
    if ($Footer) {
        $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 0, 0, 0))), 0, 770, $w, 90)
        $footerFont = New-Object System.Drawing.Font 'Segoe UI', 30, ([System.Drawing.FontStyle]::Bold)
        $g.DrawString($Footer.ToUpper(), $footerFont, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 770, $w, 90), $center)
    }
    $g.Dispose()
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bmp.Dispose()
}

$showsDir = Join-Path $Root 'Shows'
if (Test-Path $showsDir) { throw "$showsDir already exists" }
$watched = New-Object System.Collections.Generic.List[string]

foreach ($show in $shows) {
    $showDir = Join-Path $showsDir ('{0} ({1})' -f $show.Name, $show.Year)
    New-Item -ItemType Directory -Path $showDir | Out-Null
    @"
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<tvshow>
  <title>$($show.Name)</title>
  <year>$($show.Year)</year>
  <premiered>$($show.Year)-03-01</premiered>
  <status>Continuing</status>
  <plot>Demo series for testing Recently Added.</plot>
</tvshow>
"@ | Set-Content -Path (Join-Path $showDir 'tvshow.nfo') -Encoding UTF8
    New-Poster (Join-Path $showDir 'poster.jpg') $show.Name '' $show.Colors

    foreach ($season in $show.Seasons) {
        $seasonDir = Join-Path $showDir ('Season {0:D2}' -f $season.N)
        if (-not (Test-Path $seasonDir)) {
            New-Item -ItemType Directory -Path $seasonDir | Out-Null
            New-Poster (Join-Path $showDir ('season{0:D2}-poster.jpg' -f $season.N)) $show.Name ('Season {0}' -f $season.N) $show.Colors
        }

        foreach ($ep in $season.Eps) {
            $base = Join-Path $seasonDir ('{0} S{1:D2}E{2:D2}' -f $show.Name, $season.N, $ep)
            $file = "$base.mkv"
            New-Item -ItemType File -Path $file | Out-Null
            @"
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<episodedetails>
  <title>Episode $ep</title>
  <season>$($season.N)</season>
  <episode>$ep</episode>
</episodedetails>
"@ | Set-Content -Path "$base.nfo" -Encoding UTF8
            $when = $now.AddHours(-$season.Age).AddMinutes(-$ep)
            foreach ($f in @($file, "$base.nfo")) {
                (Get-Item $f).CreationTime = $when
                (Get-Item $f).LastWriteTime = $when
            }
            if ($season.Watched) { $watched.Add($file) }
        }
    }
}

$watched | Set-Content -Path (Join-Path $Root 'watched.txt') -Encoding UTF8
Write-Output ("Created {0} shows, {1} watched episodes in {2}" -f $shows.Count, $watched.Count, $showsDir)
