$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'Este iniciador exige Windows PowerShell 5.1 ou superior.'
}

$repositorio = 'JulioCesar-alt/central-aplicativos'
$nomePacote = 'Central-de-Aplicativos-Windows.zip'
$nomeSomas = 'SHA256SUMS.txt'
$api = "https://api.github.com/repos/$repositorio/releases/latest"
$temporario = Join-Path ([System.IO.Path]::GetTempPath()) ('CentralApps-' + [guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $temporario $nomePacote
$somasPath = Join-Path $temporario $nomeSomas
$extraido = Join-Path $temporario 'pacote'

try {
    [void](New-Item -ItemType Directory -Path $temporario -Force)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $cabecalhos = @{ 'User-Agent' = 'Central-de-Aplicativos'; 'Accept' = 'application/vnd.github+json' }

    Write-Host ('Repositorio: https://github.com/' + $repositorio) -ForegroundColor Cyan
    Write-Host 'Consultando a ultima release publicada pela API do GitHub...' -ForegroundColor Cyan
    $release = Invoke-RestMethod -Uri $api -Headers $cabecalhos -UseBasicParsing -ErrorAction Stop
    if (-not $release -or -not $release.tag_name) {
        throw 'A API do GitHub nao retornou uma release publica valida.'
    }
    Write-Host ('Release encontrada: ' + $release.tag_name) -ForegroundColor Green

    $assetZip = @($release.assets | Where-Object { $_.name -eq $nomePacote } | Select-Object -First 1)
    $assetSomas = @($release.assets | Where-Object { $_.name -eq $nomeSomas } | Select-Object -First 1)
    if ($assetZip.Count -eq 0 -or $assetSomas.Count -eq 0) {
        $nomes = @($release.assets | ForEach-Object { $_.name }) -join ', '
        throw ('A release ' + $release.tag_name + ' nao possui os dois anexos esperados. Assets encontrados: ' + $nomes)
    }
    if (-not $assetZip[0].browser_download_url -or -not $assetSomas[0].browser_download_url) {
        throw 'A API nao retornou os enderecos de download dos anexos.'
    }

    Write-Host ('Baixando ' + $nomePacote + '...') -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $assetZip[0].browser_download_url -OutFile $zipPath -Headers $cabecalhos -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri $assetSomas[0].browser_download_url -OutFile $somasPath -Headers $cabecalhos -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw ('Falha no download da release ' + $release.tag_name + ': ' + $_.Exception.Message + '. Confira o acesso aos arquivos em ' + $release.html_url)
    }

    $textoSomas = Get-Content -LiteralPath $somasPath -Raw -Encoding UTF8 -ErrorAction Stop
    $padrao = '(?im)^([a-f0-9]{64})\s+Central-de-Aplicativos-Windows\.zip\s*$'
    $combinacao = [regex]::Match($textoSomas, $padrao)
    if (-not $combinacao.Success) {
        throw 'O SHA256SUMS.txt nao contem o hash esperado para o ZIP.'
    }
    $hashEsperado = $combinacao.Groups[1].Value.ToUpperInvariant()
    $hashBaixado = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($hashBaixado -ne $hashEsperado) {
        throw 'SHA-256 divergente: o programa nao sera executado.'
    }
    Write-Host 'SHA-256 do ZIP conferido.' -ForegroundColor Green

    Expand-Archive -LiteralPath $zipPath -DestinationPath $extraido -Force -ErrorAction Stop
    $principal = Join-Path $extraido 'Central-de-Aplicativos.ps1'
    $catalogo = Join-Path $extraido 'catalogo.json'
    if (-not (Test-Path -LiteralPath $principal -PathType Leaf) -or -not (Test-Path -LiteralPath $catalogo -PathType Leaf)) {
        throw 'Pacote incompleto: arquivo principal ou catalogo ausente.'
    }
    $itens = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $catalogo -Raw -Encoding UTF8)
    $quantidade = 0
    foreach ($item in $itens) { $quantidade++ }
    if ($quantidade -lt 1) { throw 'O catalogo esta vazio.' }
    Write-Host ('Catalogo: ' + $quantidade + ' aplicativo(s).') -ForegroundColor Cyan

    Write-Host 'AVISO: executar programas obtidos da internet envolve riscos. Revise o codigo e confie somente no repositorio sob seu controle.' -ForegroundColor Yellow
    $resposta = Read-Host 'Abrir a Central agora? (S/N)'
    if ($resposta -notmatch '^(S|SIM)$') {
        Write-Host 'Abertura cancelada.'
        return
    }
    & powershell.exe -NoLogo -NoProfile -STA -File $principal
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ('A Central encerrou com o codigo ' + $LASTEXITCODE + '.')
    }
}
catch {
    Write-Host ('ERRO: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'O iniciador nao alterou politicas de seguranca nem instalou aplicativos.' -ForegroundColor Yellow
}
finally {
    if (Test-Path -LiteralPath $temporario) {
        Remove-Item -LiteralPath $temporario -Recurse -Force -ErrorAction SilentlyContinue
    }
}
