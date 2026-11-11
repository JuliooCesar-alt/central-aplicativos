@echo off
setlocal
cd /d "%~dp0"
title Teste de inventario WinGet - Central v8.4
set "DIRLOG=%TEMP%\CentralApps-inventario-teste"
if not exist "%DIRLOG%" mkdir "%DIRLOG%"
echo Consultando o WinGet sem instalar programas...
powershell.exe -NoLogo -NoProfile -NonInteractive -File "%~dp0Central-de-Aplicativos.ps1" -Worker -Operacao inventory -Saida "%DIRLOG%\winget.txt" -Resultado "%DIRLOG%\resultado.json"
echo.
if errorlevel 1 (
 echo [FALHA] O inventario nao foi concluido. Verifique:
 echo %DIRLOG%\winget.txt
) else (
 echo [OK] A consulta de aplicativos foi concluida.
 echo Resultado: %DIRLOG%\resultado.json
)
echo.
pause
endlocal
