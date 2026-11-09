@echo off
setlocal
set "DESTINO=%USERPROFILE%\Downloads\CentralApps\Teste-7Zip"
where winget >nul 2>&1
if errorlevel 1 (
  echo [ERRO] WinGet nao encontrado.
  pause
  exit /b 1
)
echo.
echo Este teste baixa o instalador do 7-Zip usando WinGet.
echo Nao instala o 7-Zip.
echo Pasta: %DESTINO%
choice /C SN /M "Deseja realmente baixar"
if errorlevel 2 (
  echo Teste cancelado.
  exit /b 0
)
if not exist "%DESTINO%" mkdir "%DESTINO%"
winget download --id 7zip.7zip --exact --source winget --download-directory "%DESTINO%" --accept-package-agreements --accept-source-agreements --disable-interactivity
set "CODIGO=%ERRORLEVEL%"
echo.
if not "%CODIGO%"=="0" (
  echo [ERRO] WinGet falhou com codigo %CODIGO%.
  pause
  exit /b %CODIGO%
)
echo [OK] WinGet retornou codigo zero.
echo Verifique se os arquivos foram criados nesta pasta:
echo %DESTINO%
dir /a:-d /s /b "%DESTINO%\*"
dir /a:-d /s /b "%DESTINO%\*" 2>nul | findstr /R "." >nul
if errorlevel 1 (
 echo [AVISO] Nenhum instalador foi localizado. Confira o comando ou o destino.
 pause
 exit /b 1
)
echo.
echo [OK] Arquivos encontrados no destino e WinGet retornou zero.
pause
exit /b 0
