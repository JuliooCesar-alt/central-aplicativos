@echo off
setlocal
cd /d "%~dp0"
title Auditoria WinGet - Central de Aplicativos
where winget.exe >nul 2>&1
if errorlevel 1 (
  echo [ERRO] WinGet nao encontrado neste Windows.
  pause
  exit /b 1
)
echo.
echo CENTRAL DE APLICATIVOS - AUDITORIA DOS 76 ITENS
 echo Nao instala aplicativos. Consulta IDs, fontes, versoes e URLs informadas pelo WinGet.
echo.
echo O teste pode demorar porque cada item e consultado individualmente.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Auditar-Todos-Os-Pacotes.ps1"
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" echo [ATENCAO] A auditoria encerrou com erro. Confira a mensagem acima.
echo Para auditoria detalhada, compartilhe apenas o CSV e os logs das falhas.
pause
exit /b %EXITCODE%
