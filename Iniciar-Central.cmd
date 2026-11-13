@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Central de Aplicativos - v8.6.5.6

if not exist "%~dp0Central-de-Aplicativos.ps1" goto ARQUIVOS
if not exist "%~dp0Manutencao-Drivers.ps1" goto ARQUIVOS
if not exist "%~dp0catalogo.json" goto ARQUIVOS

rem Verificacao de marca de origem: alguns HDs/pendrives nao suportam
rem os fluxos NTFS (Zone.Identifier). Falhas nessa consulta nao travam.
powershell.exe -NoLogo -NoProfile -NonInteractive -Command "$arquivos=@('Central-de-Aplicativos.ps1','Manutencao-Drivers.ps1'); foreach($n in $arquivos){$f=Join-Path (Get-Location).Path $n; try{$marca=Get-Item -LiteralPath $f -Stream 'Zone.Identifier' -ErrorAction Stop; if($null -ne $marca){exit 42}} catch {if($_.Exception -is [System.Management.Automation.ItemNotFoundException]){continue}; if($_.Exception -is [System.ComponentModel.Win32Exception]){continue}; Write-Host ('[AVISO] Nao foi possivel consultar a marca de origem de '+$n+': '+$_.Exception.Message); continue}}; exit 0"
set "VERIF=%ERRORLEVEL%"
if "%VERIF%"=="42" goto DESBLOQUEAR
if not "%VERIF%"=="0" (
  echo [AVISO] Nao foi possivel verificar a origem de todos os scripts.
  echo Verifique os arquivos antes de executar.
)
goto ABRIR

:DESBLOQUEAR
echo.
echo Estes scripts foram marcados pelo Windows como obtidos da internet.
echo Verifique o conteudo de ambos os arquivos .ps1 e a procedencia do ZIP.
choice /C SN /M "Voce revisou e confia nestes scripts e autoriza remover a marca de internet deles"
if errorlevel 2 goto CANCELAR
powershell.exe -NoLogo -NoProfile -NonInteractive -Command "foreach($n in @('Central-de-Aplicativos.ps1','Manutencao-Drivers.ps1')){Unblock-File -LiteralPath (Join-Path (Get-Location).Path $n) -ErrorAction Stop}"
if errorlevel 1 (
 echo [ERRO] Nao foi possivel desbloquear os scripts apos a autorizacao.
 echo Tente desbloquear o ZIP original nas Propriedades do Explorador, antes de extrair.
 pause
 exit /b 1
)

:ABRIR
echo Abrindo Central de Aplicativos v8.6.5.6...
rem RemoteSigned vale somente para esta execucao e nao modifica o Registro.
rem Uma politica corporativa aplicada por GPO continua tendo precedencia.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%~dp0Central-de-Aplicativos.ps1"
set "RESULTADO=%ERRORLEVEL%"
if not "%RESULTADO%"=="0" (
 echo.
 echo [ERRO] A Central nao abriu. Codigo de retorno: %RESULTADO%.
 echo Confira a politica de execucao com: powershell.exe -NoProfile -Command "Get-ExecutionPolicy -List"
 echo Se houver regra da empresa exigindo scripts assinados ou bloqueando scripts,
 echo entre em contato com o administrador. Este iniciador nao ignora regras de GPO.
 echo Se o Windows ainda identificar o script como baixado da internet,
 echo revise a origem do ZIP e, se confiavel, desbloqueie-o nas Propriedades antes de extrair.
 echo Logs da Central: %%TEMP%%\CentralApps-v8.6.5.6-*
 pause
)
exit /b %RESULTADO%

:ARQUIVOS
echo [ERRO] Arquivos essenciais ausentes. Extraia TODO o ZIP em uma pasta.
pause
exit /b 1

:CANCELAR
echo Cancelado pelo operador. Os arquivos nao foram alterados.
pause
exit /b 1
