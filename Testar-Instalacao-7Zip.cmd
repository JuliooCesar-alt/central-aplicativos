@echo off
setlocal
where winget >nul 2>&1
if errorlevel 1 (
 echo [ERRO] WinGet nao encontrado.
 pause
 exit /b 1
)
echo.
echo Este teste vai pedir ao WinGet para INSTALAR o 7-Zip.
echo Use apenas se voce for autorizado a instalar programas neste PC.
echo Pode solicitar permissao administrativa.
choice /C SN /M "Deseja realmente instalar o 7-Zip"
if errorlevel 2 (
  echo Teste cancelado.
  exit /b 0
)
winget install --id 7zip.7zip --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
set "CODIGO=%ERRORLEVEL%"
echo.
if not "%CODIGO%"=="0" (
 echo [ERRO] WinGet falhou com codigo %CODIGO%.
 pause
 exit /b %CODIGO%
)
echo [OK] WinGet retornou codigo zero. Conferindo inventario:
winget list --id 7zip.7zip --exact --accept-source-agreements
if errorlevel 1 (
 echo [AVISO] O inventario nao confirmou o pacote; verifique o Windows.
) else (
 echo [OK] O inventario foi consultado. Confira se aparece 7-Zip.
)
pause
exit /b 0
