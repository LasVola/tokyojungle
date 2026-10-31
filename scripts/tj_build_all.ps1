# Tokyo Jungle Recompiled -- full automatic build (called by BUILD.bat).
#
# Needs only, in -Root:
#   * the extracted game folder (any name; it must contain USRDIR\EBOOT.BIN and PARAM.SFO)
#   * the license file UP9000-NPUA80523_00-TOKYOJUNGLE00001.rap
# Produces, in -Root:
#   * TokyoJungle.exe        launcher (resolution / full screen screen)
#   * engine\                recompiled game, ffmpeg.exe, decrypted EBOOT.ELF
#   * launcher.ini           points the launcher at the game folder
# Work files go to -Root\.build (safe to delete after a successful build).
#
# Steps: tools (winget) -> ps3recomp + patches -> decrypt with RPCS3 ->
# generate PPU/SPU code -> compile -> launcher -> assemble.
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$Rpcs3 = '',        # existing rpcs3.exe; empty = auto-detect or download
    [switch]$Rebuild            # regenerate and recompile even if the game is built
)
$ErrorActionPreference = 'Continue'
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath
$Repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$Work = Join-Path $Root '.build'
$Log = Join-Path $Root 'build.log'
$PinnedRecomp = 'd7fff845aca42b5083791801a01d150f5f0ec18c'
$ElfSha = '6D253F6429485B43B816FD6884611377626EE95DB5DD9200EA58395C93A0812D'
New-Item -ItemType Directory -Force -Path $Work | Out-Null

function Say($text) {
    Write-Host ''
    Write-Host "==> $text" -ForegroundColor Cyan
    Add-Content -LiteralPath $Log -Value "==> $text"
}
function Fail($text) {
    Write-Host ''
    Write-Host "ERRO: $text" -ForegroundColor Red
    Write-Host "Detalhes em: $Log"
    Add-Content -LiteralPath $Log -Value "ERRO: $text"
    exit 1
}
# Run a native command, log everything, stop on failure.
function Run($what, [scriptblock]$cmd) {
    & $cmd *>&1 | ForEach-Object { "$_" } | Add-Content -LiteralPath $Log
    if ($LASTEXITCODE) { Fail "$what (codigo $LASTEXITCODE)" }
}
function Refresh-Path {
    $env:PATH = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Winget-Install($id, $extra) {
    Say "Instalando $id (winget)"
    $wargs = @('install', '-e', '--id', $id, '--silent', '--accept-package-agreements',
              '--accept-source-agreements', '--disable-interactivity') + $extra
    & winget @wargs *>&1 | ForEach-Object { "$_" } | Add-Content -LiteralPath $Log
    Refresh-Path
}
function Find-7Zip {
    foreach ($c in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}
function Find-WingetExe($pattern, $exe) {
    $pkgs = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    Get-ChildItem -Path $pkgs -Directory -Filter $pattern -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -Path $_.FullName -Recurse -Filter $exe -ErrorAction SilentlyContinue } |
        Select-Object -First 1 -ExpandProperty FullName
}

"Tokyo Jungle build $(Get-Date -Format s)" | Set-Content -LiteralPath $Log

# --- 0. Inputs ------------------------------------------------------------------
Say 'Procurando a pasta do jogo e o arquivo .rap'
$game = Get-ChildItem -LiteralPath $Root -Directory |
    Where-Object { (Test-Path (Join-Path $_.FullName 'USRDIR\EBOOT.BIN')) -and
                   (Test-Path (Join-Path $_.FullName 'PARAM.SFO')) } | Select-Object -First 1
if (-not $game) { Fail "nenhuma pasta com USRDIR\EBOOT.BIN e PARAM.SFO em $Root" }
$sfo = [IO.File]::ReadAllBytes((Join-Path $game.FullName 'PARAM.SFO'))
if (-not ([Text.Encoding]::ASCII.GetString($sfo)).Contains('NPUA80523')) {
    Fail "a pasta $($game.Name) nao e o Tokyo Jungle NPUA80523"
}
$rap = Get-ChildItem -LiteralPath $Root -Filter '*.rap' | Select-Object -First 1
if (-not $rap) { Fail "falta o arquivo .rap em $Root (UP9000-NPUA80523_00-TOKYOJUNGLE00001.rap)" }
Write-Host "    jogo: $($game.Name)   licenca: $($rap.Name)"

# --- 1. Tools ---------------------------------------------------------------------
Say 'Conferindo ferramentas (Python, CMake, Ninja, LLVM, Visual Studio Build Tools, FFmpeg)'
Refresh-Path
$py = $null
foreach ($c in @("$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
                 "$env:ProgramFiles\Python311\python.exe")) { if (Test-Path $c) { $py = $c; break } }
if (-not $py) {
    Winget-Install 'Python.Python.3.11' @()
    $py = "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe"
    if (-not (Test-Path $py)) { Fail 'Python 3.11 nao foi instalado' }
}
if (-not (Test-Path "$env:ProgramFiles\CMake\bin\cmake.exe")) { Winget-Install 'Kitware.CMake' @() }
if (-not (Test-Path "$env:ProgramFiles\LLVM\bin\clang-cl.exe")) { Winget-Install 'LLVM.LLVM' @() }
$ninja = Find-WingetExe 'Ninja-build.Ninja*' 'ninja.exe'
if (-not $ninja) { Winget-Install 'Ninja-build.Ninja' @(); $ninja = Find-WingetExe 'Ninja-build.Ninja*' 'ninja.exe' }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = $null
if (Test-Path $vswhere) {
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $vs) {
    Write-Host '    Visual Studio Build Tools: o instalador pode pedir permissao de administrador.'
    Winget-Install 'Microsoft.VisualStudio.2022.BuildTools' @('--override',
        '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { Fail 'Visual Studio Build Tools (C++) nao foi instalado' }
}
$ffmpeg = Find-WingetExe 'Gyan.FFmpeg*' 'ffmpeg.exe'
if (-not $ffmpeg) { Winget-Install 'Gyan.FFmpeg' @(); $ffmpeg = Find-WingetExe 'Gyan.FFmpeg*' 'ffmpeg.exe' }
foreach ($t in @("$env:ProgramFiles\CMake\bin\cmake.exe", "$env:ProgramFiles\LLVM\bin\clang-cl.exe", $ninja, $ffmpeg)) {
    if (-not $t -or -not (Test-Path $t)) { Fail "ferramenta faltando: $t" }
}
$env:PATH = "$(Split-Path $ninja);$env:ProgramFiles\CMake\bin;$env:ProgramFiles\LLVM\bin;" +
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer;$env:PATH"
# MSVC headers/libs for clang-cl
cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul && set" | ForEach-Object {
    if ($_ -match '^(.*?)=(.*)$') { Set-Item "env:$($matches[1])" $matches[2] }
}
Run 'pip install' { & $py -m pip install -q --disable-pip-version-check -r (Join-Path $Repo 'requirements.txt') }

# --- 2. ps3recomp + patches --------------------------------------------------------
$Recomp = Join-Path (Split-Path $Repo) 'ps3recomp'
if (-not (Test-Path (Join-Path $Recomp '.tj-patched'))) {
    Say 'Baixando o ps3recomp e aplicando os patches'
    if (Test-Path $Recomp) { Remove-Item -Recurse -Force $Recomp }
    Run 'git clone ps3recomp' { git clone -q https://github.com/sp00nznet/ps3recomp.git $Recomp }
    Run 'git checkout' { git -C $Recomp checkout -q $PinnedRecomp }
    foreach ($p in @('ps3recomp-tokyojungle-2026-10-17.patch', 'tj-build-fixes.patch')) {
        Run "git apply $p" { git -C $Recomp apply --whitespace=nowarn (Join-Path $Repo "patches\ps3recomp\$p") }
    }
    New-Item -ItemType File -Path (Join-Path $Recomp '.tj-patched') | Out-Null
}

# --- 3. Decrypt (RPCS3) -------------------------------------------------------------
$InDir = Join-Path $Repo 'input'
$Dec = Join-Path $Work 'decrypt'
New-Item -ItemType Directory -Force -Path $InDir, $Dec | Out-Null
$edat = Join-Path $game.FullName 'USRDIR\data\tj.edat'
$edatBackup = "$edat.original"
$needElf = -not (Test-Path (Join-Path $InDir 'EBOOT.ELF'))
$needEdat = (Get-Item $edat).Length -ne 22   # the decrypted tj.edat is 22 bytes
if ($needElf -or $needEdat) {
    Say 'Descriptografando o jogo com a sua licenca (RPCS3)'
    if (-not $Rpcs3) {
        foreach ($c in @('C:\Emulator\PS3\rpcs3.exe', "$env:ProgramFiles\RPCS3\rpcs3.exe",
                         (Join-Path $Work 'rpcs3\rpcs3.exe'))) { if (Test-Path $c) { $Rpcs3 = $c; break } }
    }
    if (-not $Rpcs3) {
        Write-Host '    Baixando o RPCS3 portatil (github.com/RPCS3/rpcs3-binaries-win)'
        $rel = curl.exe -sL https://api.github.com/repos/RPCS3/rpcs3-binaries-win/releases/latest | ConvertFrom-Json
        $asset = $rel.assets | Where-Object { $_.name -like '*_win64_msvc.7z' } | Select-Object -First 1
        $hash = $rel.assets | Where-Object { $_.name -like '*_win64_msvc.7z.sha256' } | Select-Object -First 1
        if (-not $asset) { Fail 'nao achei o download do RPCS3' }
        $archive = Join-Path $Work 'rpcs3.7z'
        Run 'download RPCS3' { curl.exe -sL -o $archive $asset.browser_download_url }
        if ($hash) {
            $want = ((curl.exe -sL $hash.browser_download_url) -split '\s+')[0].ToUpper()
            if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $want) { Fail 'download do RPCS3 corrompido (SHA-256)' }
        }
        $dir = Join-Path $Work 'rpcs3'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # Windows' own tar opens this .7z only on recent builds; older Windows 10
        # fails with "LZMA codec is unsupported". Then use 7-Zip (installed if missing).
        & tar.exe -xf $archive -C $dir *>&1 | ForEach-Object { "$_" } | Add-Content -LiteralPath $Log
        if ($LASTEXITCODE -or -not (Test-Path (Join-Path $dir 'rpcs3.exe'))) {
            $sevenZip = Find-7Zip
            if (-not $sevenZip) { Winget-Install '7zip.7zip' @(); $sevenZip = Find-7Zip }
            if (-not $sevenZip) { Fail 'nao consegui extrair o RPCS3: instale o 7-Zip (https://7-zip.org) e rode o BUILD.bat de novo' }
            Run 'extrair RPCS3 (7-Zip)' { & $sevenZip x -y "-o$dir" $archive }
        }
        $Rpcs3 = Join-Path $dir 'rpcs3.exe'
    }
    $exdata = Join-Path (Split-Path $Rpcs3) 'dev_hdd0\home\00000001\exdata'
    New-Item -ItemType Directory -Force -Path $exdata | Out-Null
    Copy-Item -LiteralPath $rap.FullName -Destination $exdata -Force
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Dec '*')
    Copy-Item -LiteralPath (Join-Path $game.FullName 'USRDIR\EBOOT.BIN') -Destination $Dec
    if (Test-Path $edatBackup) { Copy-Item $edatBackup (Join-Path $Dec 'tj.edat') } else { Copy-Item $edat $Dec }
    # One file per call: RPCS3 decrypts only the first path it is given.
    foreach ($f in @('EBOOT.BIN', 'tj.edat')) {
        Start-Process -FilePath $Rpcs3 -WorkingDirectory (Split-Path $Rpcs3) -Wait -WindowStyle Hidden `
            -ArgumentList @('--headless', '--decrypt', "`"$Dec\$f`"") | Out-Null
    }
    $elf = Join-Path $Dec 'EBOOT.elf'
    if (-not (Test-Path $elf)) { Fail 'o RPCS3 nao descriptografou o EBOOT (o .rap e deste jogo?)' }
    if ((Get-FileHash $elf -Algorithm SHA256).Hash -ne $ElfSha) {
        Fail 'EBOOT descriptografado diferente do esperado (versao do jogo diferente?)'
    }
    Copy-Item $elf (Join-Path $InDir 'EBOOT.ELF') -Force
    $plain = Join-Path $Dec 'tj.edat.unedat'
    if (-not (Test-Path $plain)) { Fail 'o RPCS3 nao descriptografou o tj.edat' }
    if (-not (Test-Path $edatBackup)) { Copy-Item $edat $edatBackup }
    Copy-Item $plain $edat -Force   # the runtime reads a plain tj.edat directly
}
Copy-Item (Join-Path $game.FullName 'PARAM.SFO') (Join-Path $InDir 'PARAM.SFO') -Force

# --- 4. Generate code and compile --------------------------------------------------------
$Exe = Join-Path $Repo 'build-clang\tokyojungle.exe'
Push-Location $Repo
if ($Rebuild -or -not (Test-Path $Exe)) {
    Say 'Convertendo o codigo do PS3 (PPU) -- alguns minutos'
    if (Test-Path 'generated') { Remove-Item -Recurse -Force 'generated' }
    Run 'analyze.py' { & $py scripts\analyze.py }
    Run 'fix_import_slots.py' { & $py scripts\fix_import_slots.py }
    Run 'tj_split_fixups.py' { & $py scripts\tj_split_fixups.py }
    Say 'Convertendo os 18 blocos SPU'
    Run 'tj_extract_spu_images.py' { & $py scripts\tj_extract_spu_images.py }
    Run 'tj_lift_spu.py' { & $py scripts\tj_lift_spu.py }
    Run 'fuse_spu_loops.py' { & $py -I scripts\fuse_spu_loops.py --apply }
    Say 'Compilando o jogo -- pode levar de 20 a 60 minutos'
    Run 'cmake configure' { cmake -B build-clang -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl }
    Run 'cmake build' { cmake --build build-clang }
}
if (-not (Test-Path $Exe)) { Fail 'a compilacao nao gerou o tokyojungle.exe' }

Say 'Compilando o launcher'
$launcherSrc = Join-Path $Repo 'tools\launcher\launcher.c'
$launcherExe = Join-Path $Work 'TokyoJungle.exe'
Run 'launcher' { clang-cl /O2 /nologo /MT /utf-8 -D_CRT_SECURE_NO_WARNINGS $launcherSrc "/Fe:$launcherExe" "/Fo:$Work\launcher.obj" /link /SUBSYSTEM:WINDOWS user32.lib gdi32.lib }
Pop-Location

# --- 5. Assemble ---------------------------------------------------------------------------
Say 'Montando a pasta final'
$Engine = Join-Path $Root 'engine'
New-Item -ItemType Directory -Force -Path (Join-Path $Engine 'input') | Out-Null
Copy-Item $Exe $Engine -Force
Copy-Item $ffmpeg $Engine -Force
Copy-Item (Join-Path $InDir 'EBOOT.ELF'), (Join-Path $InDir 'PARAM.SFO') (Join-Path $Engine 'input') -Force
if (-not (Test-Path (Join-Path $Engine 'controls.ini'))) { Copy-Item (Join-Path $Repo 'controls.ini') $Engine }
Copy-Item $launcherExe (Join-Path $Root 'TokyoJungle.exe') -Force
$ini = Join-Path $Root 'launcher.ini'
if (-not (Test-Path $ini)) { "[paths]`r`ngame=$($game.Name)`r`n" | Set-Content -LiteralPath $ini -Encoding ASCII }
else {
    $text = Get-Content -LiteralPath $ini -Raw
    if ($text -notmatch '(?m)^game=') { Add-Content -LiteralPath $ini -Value "`r`n[paths]`r`ngame=$($game.Name)" }
}

Write-Host ''
Write-Host 'PRONTO! Abra o TokyoJungle.exe para jogar.' -ForegroundColor Green
Write-Host "A pasta $Work pode ser apagada (ocupa espaco; so serve para recompilar)."
exit 0
