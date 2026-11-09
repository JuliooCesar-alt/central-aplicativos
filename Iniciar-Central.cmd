@echo off
setlocal
cd /d "%~dp0"
title Central de Aplicativos - v8
if not exist "%~dp0Central-de-Aplicativos.ps1" (
 echo [ERRO] Central-de-Aplicativos.ps1 ausente. Extraia o ZIP por completo.
 pause
 exit /b 1
)
if not exist "%~dp0catalogo.json" (
 echo [ERRO] catalogo.json ausente. Extraia o ZIP por completo.
 pause
 exit /b 1
)
rem Verifica somente a marca de arquivo baixado da Internet.
powershell.exe -NoLogo -NoProfile -Command "$f=Join-Path (Get-Location).Path 'Central-de-Aplicativos.ps1'; if(Get-Item -LiteralPath $f -Stream Zone.Identifier -ErrorAction SilentlyContinue){exit 42}else{exit 0}"
if errorlevel 42 goto DESBLOQUEAR
goto ABRIR
:DESBLOQUEAR
echo.
echo O script foi marcado como baixado da internet e nao possui assinatura digital.
echo Leia e confira o arquivo antes de optar por desbloquea-lo.
choice /C SN /M "Voce conferiu o script e autoriza desbloquear este arquivo"
if errorlevel 2 goto CANCELAR
powershell.exe -NoLogo -NoProfile -Command "$f=Join-Path (Get-Location).Path 'Central-de-Aplicativos.ps1'; Unblock-File -LiteralPath $f -ErrorAction Stop"
if errorlevel 1 (
 echo [ERRO] Nao foi possivel desbloquear. Consulte o TI.
 pause
 exit /b 1
)
:ABRIR
echo Abrindo Central de Aplicativos...
powershell.exe -NoLogo -NoProfile -STA -File "%~dp0Central-de-Aplicativos.ps1"
set RESULTADO=%ERRORLEVEL%
if not "%RESULTADO%"=="0" (
 echo.
 echo [ERRO] PowerShell encerrou com codigo %RESULTADO%.
 echo Para politica corporativa que exige scripts assinados, procure o TI.
 echo Logs: %%TEMP%%\CentralApps-v8-*
 pause
)
exit /b %RESULTADO%
:CANCELAR
echo Cancelado. Nenhum script foi desbloqueado.
pause
exit /b 1
