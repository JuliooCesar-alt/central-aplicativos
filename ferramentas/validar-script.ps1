$ErrorActionPreference = 'Stop'
$raiz = Split-Path $PSScriptRoot -Parent
$arquivos = @(
    'Central-de-Aplicativos.ps1',
    'Manutencao-Drivers.ps1',
    'Auditar-Todos-Os-Pacotes.ps1',
    'iniciar.ps1'
)
foreach ($nome in $arquivos) {
    $arquivo = Join-Path $raiz $nome
    if (-not (Test-Path -LiteralPath $arquivo -PathType Leaf)) {
        throw "Arquivo necessario ausente: $nome"
    }
    $tokens = $null
    $erros = $null
    [System.Management.Automation.Language.Parser]::ParseFile($arquivo, [ref]$tokens, [ref]$erros) | Out-Null
    if (@($erros).Count -gt 0) {
        $erros | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        exit 1
    }
    Write-Host ('Sintaxe validada: ' + $nome)
}
