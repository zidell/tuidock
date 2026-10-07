param(
    [string]$QtRoot = $env:QT_ROOT_DIR,
    [string]$BuildDir = 'build-win-release',
    [switch]$Package
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $QtRoot -or -not (Test-Path -LiteralPath "$QtRoot/lib/cmake/Qt6/Qt6Config.cmake")) {
    throw 'Pass -QtRoot <Qt 6.10 MSVC directory>, or set QT_ROOT_DIR.'
}
$QtRoot = (Resolve-Path -LiteralPath $QtRoot).Path
$cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
if (-not $cmake) { $cmake = "$env:ProgramFiles/CMake/bin/cmake.exe" }
if (-not (Test-Path -LiteralPath $cmake)) { throw 'Install CMake first.' }
Push-Location $repoRoot
try {
    & $cmake -S windows -B $BuildDir -G 'Visual Studio 17 2022' -A x64 "-DCMAKE_PREFIX_PATH=$QtRoot" -DBUILD_TESTING=ON
    if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed.' }
    & $cmake --build $BuildDir --config Release --parallel
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
    $go = (Get-Command go -ErrorAction SilentlyContinue).Source
    if (-not $go) { $localGo = Join-Path $repoRoot 'dist/_toolchains/go/bin/go.exe'; if (Test-Path -LiteralPath $localGo) { $go = $localGo } }
    if (-not $go) { throw 'Install Go 1.21 or newer to test the Go connection.' }
    & $go test -race .
    if ($LASTEXITCODE -ne 0) { throw 'Go tests failed.' }
    & $go build -o "$BuildDir/Release/go_fixture.exe" ./windows/tests/go_fixture
    if ($LASTEXITCODE -ne 0) { throw 'Go fixture build failed.' }
    $savedPath = $env:PATH
    try {
        $env:PATH = "$(Join-Path $QtRoot 'bin');$savedPath"
        & "$([IO.Path]::GetDirectoryName($cmake))/ctest.exe" --test-dir $BuildDir -C Release --output-on-failure
        $testExit = $LASTEXITCODE
        if (Test-Path -LiteralPath "$BuildDir/terminal-tests.txt") { Get-Content -Encoding UTF8 -LiteralPath "$BuildDir/terminal-tests.txt" }
        if (Test-Path -LiteralPath "$BuildDir/app-tests.txt") { Get-Content -Encoding UTF8 -LiteralPath "$BuildDir/app-tests.txt" }
        if ($testExit -ne 0) { throw 'Tests failed.' }
    } finally { $env:PATH = $savedPath }
    if ($Package) {
        $stage = [IO.Path]::GetFullPath((Join-Path $repoRoot 'dist/TUIDock-windows-x64'))
        $distRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'dist'))
        # 이 스크립트가 만든 패키지 폴더만 비운다. Qt 모듈을 뺐을 때 오래된 DLL이 남지 않게 한다.
        if (-not $stage.StartsWith($distRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Package directory must be inside this repository dist directory.'
        }
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        New-Item -ItemType Directory -Force $stage | Out-Null
        Copy-Item -LiteralPath "$BuildDir/Release/tuidock.exe", 'LICENSE', 'LICENSE.MIT' -Destination $stage
        Copy-Item -LiteralPath 'launcher/fonts' -Destination $stage -Recurse -Force
        New-Item -ItemType Directory -Force "$stage/licenses" | Out-Null
        Copy-Item -LiteralPath 'launcher/libvterm/LICENSE' -Destination "$stage/licenses/libvterm.txt"
        Copy-Item -LiteralPath 'windows/licenses/Qt-LGPL-3.0.txt' -Destination "$stage/licenses/Qt-LGPL-3.0.txt"
        Copy-Item -LiteralPath 'LICENSE' -Destination "$stage/licenses/Qt-GPL-3.0.txt"
        & "$QtRoot/bin/windeployqt.exe" --release --compiler-runtime --no-translations --skip-plugin-types generic,iconengines --exclude-plugins qpdf,qsvg "$stage/tuidock.exe"
        if ($LASTEXITCODE -ne 0) { throw 'Qt deployment failed.' }
        # VS 개발 셸 밖에서도 app-local CRT를 동봉한다.
        $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
        $vsInstall = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $vsInstall) { throw 'MSVC redistributable directory not found.' }
        $redist = Get-ChildItem -LiteralPath "$vsInstall/VC/Redist/MSVC" -Directory |
            Where-Object Name -Match '^14\.' | Sort-Object Name -Descending | Select-Object -First 1
        Copy-Item -Path "$($redist.FullName)/x64/Microsoft.VC143.CRT/*.dll" -Destination $stage
        foreach ($file in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
            if (-not (Test-Path -LiteralPath "$stage/$file")) { throw "Missing MSVC runtime: $file" }
        }
        Compress-Archive -Path $stage -DestinationPath 'dist/TUIDock-windows-x64.zip' -Force
    }
} finally { Pop-Location }
