@echo off
setlocal
cd /d "%~dp0"
title Verificar catalogo - Central v8
powershell.exe -NoLogo -NoProfile -Command "$ErrorActionPreference='Stop'; $raw = Get-Content -LiteralPath '.\catalogo.json' -Raw -Encoding UTF8; $dados = ConvertFrom-Json -InputObject $raw; $lista=New-Object System.Collections.ArrayList; foreach($app in $dados){[void]$lista.Add($app)}; Write-Host ('Aplicativos carregados: ' + $lista.Count); $lista | Group-Object Grupo | Sort-Object Name | ForEach-Object { Write-Host (' - ' + $_.Name + ': ' + $_.Count) }; if($lista.Count -lt 1){Write-Host '[ERRO] O catalogo esta vazio.'; exit 1}else{Write-Host '[OK] Catalogo carregado.'; exit 0}"
set "CODIGO=%ERRORLEVEL%"
echo.
pause
exit /b %CODIGO%
