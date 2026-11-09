@echo off
setlocal
title Diagnostico WinGet
where winget >nul 2>&1
if errorlevel 1 (
 echo [ERRO] WinGet nao encontrado.
 echo Verifique a instalacao do App Installer.
 pause
 exit /b 1
)
echo === Versao WinGet ===
winget --version
echo.
echo === Consultando pacote oficial 7-Zip (sem instalar) ===
winget show --id 7zip.7zip --exact --source winget --accept-source-agreements
if errorlevel 1 (
 echo.
 echo [ERRO] Consulta falhou. Verifique conexao, fontes e politicas de rede.
) else (
 echo.
 echo [OK] Catalogo acessivel. Isso NAO significa download ou instalacao validada.
)
pause
