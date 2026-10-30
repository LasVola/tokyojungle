@echo off
setlocal
rem ==========================================================================
rem  Tokyo Jungle Recompiled - build automatico
rem
rem  Coloque este arquivo numa pasta junto com:
rem    - a pasta do jogo extraido (com USRDIR e PARAM.SFO dentro)
rem    - o arquivo UP9000-NPUA80523_00-TOKYOJUNGLE00001.rap
rem  e de dois cliques. No fim aparece o TokyoJungle.exe nesta pasta.
rem ==========================================================================
set "ROOT=%~dp0"
set "REPO=https://github.com/SEU_USUARIO/tokyojungle.git"
if defined TJ_REPO set "REPO=%TJ_REPO%"
set "SRC=%ROOT%.build\tokyojungle"

where git >nul 2>nul
if errorlevel 1 (
    echo Instalando o Git...
    winget install -e --id Git.Git --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    set "PATH=%PATH%;%ProgramFiles%\Git\cmd"
)

if not exist "%SRC%\.git" (
    echo Baixando o projeto de %REPO% ...
    git clone -q "%REPO%" "%SRC%" || goto :erro
) else (
    git -C "%SRC%" pull -q --ff-only
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%\scripts\tj_build_all.ps1" -Root "%ROOT%." %*
if errorlevel 1 goto :erro
echo.
pause
exit /b 0

:erro
echo.
echo O build parou com erro. Veja o arquivo build.log nesta pasta.
pause
exit /b 1
