Set-StrictMode -Version 2.0

$script:QvwImageFixtureText = '千问视觉 QVW-7319'
$script:QvwImageFixtureRelations = @(
    'red circle left of blue square',
    'green triangle below red circle',
    'green triangle below blue square'
)

function New-QvwImageFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Image fixture path is required.'
    }

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolvedPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }

    $bitmap = $null
    $graphics = $null
    $background = $null
    $redBrush = $null
    $blueBrush = $null
    $greenBrush = $null
    $blackBrush = $null
    $font = $null
    $format = $null
    try {
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        }
        catch {
            throw 'System.Drawing is required to create the Windows PNG fixture.'
        }

        # Keep the canvas, colors, text, and render settings constant. The
        # fixture intentionally contains no user data, timestamps, or paths.
        $bitmap = New-Object System.Drawing.Bitmap(900, 560, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb))
        $bitmap.SetResolution(96, 96)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

        $background = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $redBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Red)
        $blueBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Blue)
        $greenBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::LimeGreen)
        $blackBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
        $font = New-Object System.Drawing.Font('Arial', 30, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $format = New-Object System.Drawing.StringFormat
        $format.Alignment = [System.Drawing.StringAlignment]::Near
        $format.LineAlignment = [System.Drawing.StringAlignment]::Near

        $graphics.DrawString($script:QvwImageFixtureText, $font, $blackBrush, (New-Object System.Drawing.PointF(42, 35)), $format)

        # Red circle is intentionally left of the blue square. Their centers
        # share a row so the relation is unambiguous to a vision model.
        $graphics.FillEllipse($redBrush, 105, 175, 170, 170)
        $graphics.DrawRectangle([System.Drawing.Pens]::Black, 105, 175, 170, 170)
        $graphics.FillRectangle($blueBrush, 520, 175, 170, 170)
        $graphics.DrawRectangle([System.Drawing.Pens]::Black, 520, 175, 170, 170)

        # Green triangle is centered below both shapes.
        $triangle = New-Object 'System.Drawing.Point[]' 3
        $triangle[0] = New-Object System.Drawing.Point(400, 390)
        $triangle[1] = New-Object System.Drawing.Point(300, 500)
        $triangle[2] = New-Object System.Drawing.Point(500, 500)
        $graphics.FillPolygon($greenBrush, $triangle)
        $graphics.DrawPolygon([System.Drawing.Pens]::Black, $triangle)

        $bitmap.Save($resolvedPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        foreach ($resource in @($format, $font, $blackBrush, $greenBrush, $blueBrush, $redBrush, $background, $graphics, $bitmap)) {
            if ($null -ne $resource) {
                try { $resource.Dispose() } catch { }
            }
        }
    }

    $sha256 = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash.ToUpperInvariant()
    return [pscustomobject][ordered]@{
        Path = $resolvedPath
        Sha256 = $sha256
        ExpectedText = 'QVW-7319'
        ExpectedRelations = @($script:QvwImageFixtureRelations)
    }
}

Export-ModuleMember -Function New-QvwImageFixture
