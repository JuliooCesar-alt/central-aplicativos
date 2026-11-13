# Auditoria de catalogo WinGet - Central de Aplicativos v8.6.5.6
# Somente consultas: nao instala, nao atualiza fontes, nao baixa nem executa instaladores.
[CmdletBinding()]
param(
    [switch]$VerificarUrlsInstalador,
    [string]$PastaSaida = ''
)

$ErrorActionPreference = 'Stop'
$catalogoPath = Join-Path $PSScriptRoot 'catalogo.json'
if (-not (Test-Path -LiteralPath $catalogoPath)) { throw 'catalogo.json nao encontrado na pasta do auditor.' }
$catalogo = @(ConvertFrom-Json -InputObject (Get-Content -LiteralPath $catalogoPath -Raw -Encoding UTF8))
if ($catalogo.Count -eq 1 -and $catalogo[0] -is [array]) { $catalogo = @($catalogo[0]) }
if ($catalogo.Count -ne 76) { Write-Warning "Este catalogo possui $($catalogo.Count) entradas (esperadas: 76)." }
$wg = Get-Command winget.exe -CommandType Application -ErrorAction Stop
$quando = Get-Date -Format 'yyyyMMdd_HHmmss'
if ([string]::IsNullOrWhiteSpace($PastaSaida)) { $PastaSaida = Join-Path $PSScriptRoot ('Auditoria-' + $quando) }
$logs = Join-Path $PastaSaida 'Logs-Consultas'
New-Item -ItemType Directory -Path $logs -Force | Out-Null

function Consultar-Link-Head([string]$url) {
    if (-not $url) { return 'URL_NAO_INFORMADA' }
    if (-not $url.StartsWith('https://',[StringComparison]::OrdinalIgnoreCase)) { return 'URL_NAO_HTTPS' }
    try {
        $uri = [Uri]$url
        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.Method = 'HEAD'
        $request.Timeout = 12000
        $request.ReadWriteTimeout = 12000
        $request.AllowAutoRedirect = $true
        $request.MaximumAutomaticRedirections = 5
        $response = $request.GetResponse()
        try { return ('HTTP_' + [int]$response.StatusCode) } finally { $response.Close() }
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $http = [int]$_.Exception.Response.StatusCode
            $_.Exception.Response.Close()
            if ($http -in @(403,405,429)) { return ('HEAD_NAO_CONCLUSIVO_HTTP_' + $http) }
            return ('HTTP_' + $http)
        }
        return ('NAO_VERIFICAVEL_' + $_.Exception.Status)
    } catch { return 'NAO_VERIFICAVEL' }
}

function Classificar-Falha([string]$saida, [int64]$codigo) {
    if ($saida -match '(?i)0x8a15005e|server certificate did not match|certificado.{0,60}(correspond|esperad)') { return 'ERRO_CERTIFICADO_FONTE' }
    if ($saida -match '(?i)0x8a150014|no package found|nenhum pacote|no packages found|no matching package|nenhum aplicativo encontrado') { return 'NAO_ENCONTRADO' }
    if ($saida -match '(?i)0x8a150010|no applicable installer|nenhum instalador aplic.vel') { return 'SEM_INSTALADOR_COMPATIVEL' }
    if ($saida -match '(?i)0x8a150012|source name does not exist|fonte.{0,30}n.o existe') { return 'FONTE_NAO_CONFIGURADA' }
    return ('FALHA_CONSULTA_' + $codigo)
}

$infoWg = @(& $wg.Source --info 2>&1 | Out-String)
$infoWg | Set-Content -LiteralPath (Join-Path $PastaSaida 'WinGet-Info.txt') -Encoding UTF8
$fontes = @(& $wg.Source source list 2>&1 | Out-String)
$fontes | Set-Content -LiteralPath (Join-Path $PastaSaida 'Fontes-WinGet.txt') -Encoding UTF8

$dados = New-Object System.Collections.ArrayList
$contador = 0
foreach ($item in $catalogo) {
    $contador++
    $nome = [string]$item.Nome
    $id = [string]$item.Id
    $tipo = [string]$item.Tipo
    $fonte = if ([string]$item.Fonte) { [string]$item.Fonte } else { 'winget' }
    $arq = [string]$item.Arquitetura
    $resultado = 'NAO_TESTADO'
    $codigo = $null
    $versao = ''
    $urlInst = ''
    $checagemUrl = 'NAO_SOLICITADA'
    $observacao = ''
    $texto = ''

    Write-Progress -Activity 'Auditoria do catalogo WinGet (sem instalar programas)' -Status ("$contador de $($catalogo.Count): $nome") -PercentComplete ([int](100 * ($contador-1) / [Math]::Max(1,$catalogo.Count)))
    if ($tipo -eq 'Painel') {
        $resultado = 'NAO_APLICAVEL_ATALHO_DO_WINDOWS'
        $observacao = 'Atalho integrado ao Windows, sem ID WinGet.'
    } elseif ([string]::IsNullOrWhiteSpace($id)) {
        $resultado = 'ID_AUSENTE'
    } else {
        $argsWg = @()
        if ($tipo -eq 'BuscaNomeAV') {
            $argsWg = @('search','--name',$id,'--exact','--source',$fonte,'--accept-source-agreements','--disable-interactivity')
            $observacao = 'Busca por nome; mesmo um resultado encontrado nao garante ID exato nem uso empresarial permitido.'
        } else {
            $argsWg = @('show','--id',$id,'--exact','--source',$fonte,'--accept-source-agreements','--disable-interactivity')
            if ($arq -in @('x64','x86','arm64','arm')) { $argsWg += @('--architecture',$arq) }
        }
        $logArquivo = Join-Path $logs ('{0:D2}-{1}.txt' -f $contador,($id -replace '[^a-zA-Z0-9_.-]','_'))
        try {
            $ErrorActionPreference = 'Continue'
            $texto = & $wg.Source @argsWg 2>&1 | Out-String -Width 800
            $codigo = [int64]$LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            if ($codigo -eq 0) {
                $resultado = if ($tipo -eq 'BuscaNomeAV') { 'NOME_ENCONTRADO_REVISAR' } else { 'METADADOS_ENCONTRADOS' }
                if ($tipo -eq 'BuscaNomeAV') { $observacao += ' Resultado encontrado, mas esta entrada exige revisao manual.' }
            } else { $resultado = Classificar-Falha $texto $codigo }
        } catch {
            $ErrorActionPreference = 'Stop'
            $texto += "`r`nEXCECAO: $($_.Exception.Message)"
            $resultado = 'EXCECAO_NA_CONSULTA'
        }
        ("Comando: winget " + ($argsWg -join ' ') + "`r`n`r`n" + $texto) | Set-Content -LiteralPath $logArquivo -Encoding UTF8
        if ($texto -match '(?im)^\s*(?:Version|Vers[aã]o|Versi[oó]n)\s*:\s*(\S+)') { $versao = $Matches[1] }
        if ($texto -match '(?im)^\s*(?:Installer\s+Url|Installer\s+URL|URL\s+do\s+instalador|URL\s+del\s+instalador)\s*:\s*(https?://\S+)') { $urlInst = $Matches[1] }
        if ($VerificarUrlsInstalador -and $tipo -ne 'BuscaNomeAV') { $checagemUrl = Consultar-Link-Head $urlInst }
        if ($id -eq 'Adobe.Acrobat.Reader.64-bit' -and $resultado -eq 'METADADOS_ENCONTRADOS') {
            $observacao += ' ID encontrado; isso nao comprova instalacao. Instalador Adobe pode falhar por conflito com Acrobat Pro ou por outros motivos.'
        }
        if ($id -eq '9NKSQGP7F2NH' -and $resultado -eq 'ERRO_CERTIFICADO_FONTE') {
            $observacao += ' Certificado da fonte msstore falhou: verificar App Installer, proxy e rede; nao ignorar certificado.'
        }
    }
    [void]$dados.Add([pscustomobject]@{
        Numero=$contador; Grupo=[string]$item.Grupo; Aplicativo=$nome; Id=$id; Fonte=$fonte;
        Arquitetura=$arq; Tipo=$tipo; Resultado=$resultado; CodigoWinGet=$codigo;
        VersaoNoCatalogo=$versao; UrlDoInstalador=$urlInst; VerificacaoHEAD=$checagemUrl; Observacao=$observacao
    })
    Write-Host ('[{0,2}/{1}] {2}: {3}' -f $contador,$catalogo.Count,$nome,$resultado)
}
Write-Progress -Activity 'Auditoria do catalogo WinGet' -Completed

$csv = Join-Path $PastaSaida ('Resultado-' + $catalogo.Count + '-Entradas.csv')
$dados | Export-Csv -LiteralPath $csv -Delimiter ';' -NoTypeInformation -Encoding UTF8
$qtde = @($dados | Where-Object Resultado -eq 'METADADOS_ENCONTRADOS').Count
$erros = @($dados | Where-Object { $_.Resultado -notin @('METADADOS_ENCONTRADOS','NOME_ENCONTRADO_REVISAR','NAO_APLICAVEL_ATALHO_DO_WINDOWS') }).Count
$totais = @($dados | Group-Object Resultado | Sort-Object Count -Descending | ForEach-Object { '{0}: {1}' -f $_.Name,$_.Count })
$resumo = @(
    'CENTRAL DE APLICATIVOS - AUDITORIA WINGET',
    ('Data: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
    ('Computador: ' + $env:COMPUTERNAME),
    ('Itens do catalogo: ' + $catalogo.Count),
    ('Entradas com metadados localizados: ' + $qtde),
    ('Entradas com erro/sem resultado conclusivo: ' + $erros),
    'IMPORTANTE: winget show apenas consulta catalogo e metadados; nao testa download nem instalacao.',
    'Um link HEAD 403/405/429 nao determina indisponibilidade real do download.',
    '', 'RESULTADOS:', ($totais -join "`r`n"), '', ('CSV: ' + $csv)
)
$resumo | Set-Content -LiteralPath (Join-Path $PastaSaida 'LEIA-O-RESULTADO.txt') -Encoding UTF8
Write-Host ''
Write-Host 'Auditoria concluida. Nenhum aplicativo foi instalado ou baixado.' -ForegroundColor Green
Write-Host ('Relatorio: ' + $csv)
Write-Host 'ATENCAO: METADADOS_ENCONTRADOS nao significa que o instalador funcionara.' -ForegroundColor Yellow
