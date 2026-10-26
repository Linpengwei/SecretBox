param([switch]$SkipAndroid, [switch]$SkipWindows)
$ErrorActionPreference = 'Stop'
$mauiRoot = Split-Path -Parent $PSScriptRoot
Push-Location $mauiRoot
try {
    dotnet restore SecretBox.sln --disable-parallel
    if ($LASTEXITCODE -ne 0) { throw 'Dependency restore failed.' }
    dotnet test SecretBox.Core.Tests/SecretBox.Core.Tests.csproj --no-restore --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }
    if (-not $SkipWindows) {
        dotnet build SecretBox.Maui/SecretBox.Maui.csproj -f net10.0-windows10.0.19041.0 --no-restore --nologo
        if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
    }
    if (-not $SkipAndroid) {
        dotnet build SecretBox.Maui/SecretBox.Maui.csproj -f net10.0-android --no-restore --nologo
        if ($LASTEXITCODE -ne 0) { throw 'Android build failed.' }
    }
} finally { Pop-Location }
