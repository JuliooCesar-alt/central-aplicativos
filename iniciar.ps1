# Verificacao de versao em tempo de execucao para ser compativel com Invoke-Expression
<#
Central de Aplicativos - iniciador via GitHub Releases.
Publicar este arquivo em 'main/iniciar.ps1' para permitir um comando unico no PowerShell.
ATENCAO: revise o codigo antes de executar. A release deve ser publica.
Nao desativa nem contorna politicas de execucao.
#>
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 ou superior e necessario.' }
$repositorio = 'JulioCesar-alt/central-aplicativos'
$nomePacote = 'Central-de-Aplicativos-Windows.zip'
$nomeSomas = 'SHA256SUMS.txt'

if ($repositorio -match '^SEU-USUARIO/' -or $repositorio -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw 'Configure $repositorio no arquivo iniciar.ps1 com USUARIO/REPOSITORIO antes de publicar.'
}
if ($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {
    throw 'Este iniciador destina-se ao Windows.'
}

$base = "https://github.com/$repositorio/releases/latest/download"
$temporario = Join-Path ([IO.Path]::GetTempPath()) ('CentralApps-' + [guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $temporario $nomePacote
$somasPath = Join-Path $temporario $nomeSomas
$diretorioExtraido = Join-Path $temporario 'pacote'

try {
    [void](New-Item -ItemType Directory -Path $temporario -Force)
    # TLS 1.2 necessario em alguns ambientes antigos do Windows PowerShell 5.1.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-Host "Repositorio: https://github.com/$repositorio" -ForegroundColor Cyan
    Write-Host 'Consultando a release mais recente...' -ForegroundColor Cyan
    Invoke-WebRequest -Uri "$base/$nomePacote" -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    Invoke-WebRequest -Uri "$base/$nomeSomas" -OutFile $somasPath -UseBasicParsing -ErrorAction Stop

    $somas = Get-Content -LiteralPath $somasPath -Raw -ErrorAction Stop
    $padrao = '(?im)^([a-f0-9]{64})\s+Central-de-Aplicativos-Windows\.zip\s*$'
    $correspondencia = [regex]::Match($somas, $padrao)
    if (-not $correspondencia.Success) {
        throw 'SHA256SUMS.txt nao possui o hash esperado do pacote ZIP.'
    }
    $hashEsperado = $correspondencia.Groups[1].Value.ToUpperInvariant()
    $hashObtido = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($hashEsperado -ne $hashObtido) {
        throw 'O SHA-256 do pacote nao confere com o publicado. Execucao cancelada.'
    }
    Write-Host 'Integridade SHA-256 do download verificada.' -ForegroundColor Green

    Expand-Archive -LiteralPath $zipPath -DestinationPath $diretorioExtraido -Force
    $principal = Join-Path $diretorioExtraido 'Central-de-Aplicativos.ps1'
    $catalogo = Join-Path $diretorioExtraido 'catalogo.json'
    if (-not (Test-Path -LiteralPath $principal -PathType Leaf) -or -not (Test-Path -LiteralPath $catalogo -PathType Leaf)) {
        throw 'Pacote incompleto: interface ou catalogo ausente.'
    }
    $dadosCatalogo = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $catalogo -Raw -Encoding UTF8)
    $quantidade = 0
    foreach ($aplicativo in $dadosCatalogo) { $quantidade++ }
    if ($quantidade -lt 1) { throw 'Catalogo vazio; execucao cancelada.' }

    Write-Host ("Pacote: {0} aplicativo(s) no catalogo." -f $quantidade)
    Write-Host 'O hash nao comprova quem publicou a release. Execute somente se confiar no repositorio.' -ForegroundColor Yellow
    $resposta = Read-Host 'Autoriza abrir a Central de Aplicativos agora? (S/N)'
    if ($resposta -notmatch '^(S|SIM)$') {
        Write-Host 'Cancelado pelo usuario.'
        return
    }
    # Novo processo STA para WinForms; mantem as restricoes de execucao do Windows.
    & powershell.exe -NoLogo -NoProfile -STA -File $principal
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ("A interface encerrou com codigo {0}. Consulte os logs locais." -f $LASTEXITCODE)
    }
}
catch {
    Write-Host ('ERRO: ' + $_.Exception.Message) -ForegroundColor Red
    throw
}
finally {
    if (Test-Path -LiteralPath $temporario) {
        Remove-Item -LiteralPath $temporario -Recurse -Force -ErrorAction SilentlyContinue
    }
}
