$arquivos = @(
  (Join-Path (Split-Path $PSScriptRoot -Parent) 'Central-de-Aplicativos.ps1'),
  (Join-Path (Split-Path $PSScriptRoot -Parent) 'iniciar.ps1')
)
foreach ($arquivo in $arquivos) {
  $tokens = $null
  $erros = $null
  [System.Management.Automation.Language.Parser]::ParseFile($arquivo, [ref]$tokens, [ref]$erros) | Out-Null
  if (@($erros).Count -gt 0) {
    $erros | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
  }
  Write-Host ('Sintaxe validada: ' + [IO.Path]::GetFileName($arquivo))
}
