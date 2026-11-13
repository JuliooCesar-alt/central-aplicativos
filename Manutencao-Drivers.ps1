# Modulo de manutencao da Central - laboratorio local v8.6.5.1
# Backup de arquivos e drivers, diagnostico e instalacao de arquivos INF oficiais.
# Nao formata, nao apaga dados, nao instala drivers automaticamente.
param(
    [switch]$Worker,
    [string]$JobFile = '',
    [switch]$Inventario,
    [string]$InventarioArquivo = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function EscreverMensagem([string]$texto) {
    Write-Host ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $texto)
}

function CriarRelatorioComputador([string]$pasta) {
    $sistema = Get-CimInstance -ClassName Win32_OperatingSystem
    $computador = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $dados = [ordered]@{
        Computador = $env:COMPUTERNAME
        Data = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Fabricante = [string]$computador.Manufacturer
        Modelo = [string]$computador.Model
        NumeroSerie = [string]$bios.SerialNumber
        Sistema = [string]$sistema.Caption
        Versao = [string]$sistema.Version
        Build = [string]$sistema.BuildNumber
        Arquitetura = [string]$sistema.OSArchitecture
        UsuarioOrigem = [string]$env:USERNAME
    }
    $dados | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $pasta 'computador.json') -Encoding UTF8
    ($dados.GetEnumerator() | ForEach-Object { $_.Key + ': ' + $_.Value }) | Set-Content -LiteralPath (Join-Path $pasta 'LEIA-ME-BACKUP.txt') -Encoding UTF8
    try {
        Get-CimInstance -ClassName Win32_PnPSignedDriver |
            Select-Object DeviceName, DeviceClass, Manufacturer, DriverProviderName, DriverVersion, InfName, DriverDate, IsSigned |
            Export-Csv -LiteralPath (Join-Path $pasta 'drivers-instalados.csv') -NoTypeInformation -Encoding UTF8
    } catch { EscreverMensagem ('Aviso: relatorio de drivers incompleto: ' + $_.Exception.Message) }
    try {
        Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Select-Object Class, FriendlyName, Status, InstanceId |
            Export-Csv -LiteralPath (Join-Path $pasta 'dispositivos.csv') -NoTypeInformation -Encoding UTF8
    } catch { EscreverMensagem ('Aviso: inventario PnP incompleto: ' + $_.Exception.Message) }
}

function EstaElevado {
    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identidade)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function BackupArquivos([object]$tarefa,[string]$pasta) {
    $arquivoLog = Join-Path $pasta 'backup-arquivos.log'
    $sucesso = 0; $avisos = 0; $erros = 0
    foreach ($entrada in @($tarefa.Fontes)) {
        $rotulo = [string]$entrada.Nome
        $origem = [string]$entrada.Caminho
        if ([string]::IsNullOrWhiteSpace($origem) -or -not (Test-Path -LiteralPath $origem -PathType Container)) {
            $avisos++
            ('Pasta nao encontrada: ' + $rotulo + ' -> ' + $origem) | Add-Content -LiteralPath $arquivoLog -Encoding UTF8
            EscreverMensagem ('Pasta nao localizada: ' + $rotulo)
            continue
        }
        $destino = Join-Path (Join-Path (Join-Path $pasta '_Temporario') 'Arquivos') $rotulo
        [void](New-Item -ItemType Directory -Path $destino -Force)
        $origemCompleta = [IO.Path]::GetFullPath($origem).TrimEnd([char]'\')
        $destCompleto = [IO.Path]::GetFullPath($destino).TrimEnd([char]'\')
        if ($destCompleto.StartsWith($origemCompleta + '\',[StringComparison]::OrdinalIgnoreCase)) {
            throw ('Destino fica dentro da origem: ' + $origem + '. Escolha outro HD ou pasta.')
        }
        EscreverMensagem ('Copiando ' + $rotulo + '...')
        $args = @($origem,$destino,'/E','/COPY:DAT','/DCOPY:DAT','/R:1','/W:1','/XJ','/XJD','/XJF','/NP','/NFL','/NDL')
        ('--- ' + $rotulo + ' ---') | Add-Content -LiteralPath $arquivoLog -Encoding UTF8
        & robocopy.exe @args 2>&1 | Out-File -LiteralPath $arquivoLog -Append -Encoding UTF8
        $codigo = [int]$LASTEXITCODE
        if ($codigo -ge 8) { $erros++; EscreverMensagem ('ATENCAO: houve falhas ao copiar ' + $rotulo + '. Confira o log.') }
        else { $sucesso++; EscreverMensagem ('Copia concluida: ' + $rotulo) }
        ('Codigo RoboCopy: ' + $codigo) | Add-Content -LiteralPath $arquivoLog -Encoding UTF8
    }
    return [pscustomobject]@{Concluidas=$sucesso; NaoLocalizadas=$avisos; ComErros=$erros}
}

# Lista pacotes OEM do Driver Store, nao aplicativos nem drivers nativos do Windows.
# Get-WindowsDriver fornece objetos, evitando analisar texto traduzido do PnPUtil.
function LerProp([object]$objeto,[string]$nome) {
    if ($null -eq $objeto) { return '' }
    $p=$objeto.PSObject.Properties[$nome]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    return [string]$p.Value
}
function ObterPacotesDrivers {
    $pacotes=@(); $script:OrigemInventario='DISM - todos os pacotes OEM do armazenamento'
    try {
        $origem=@(Get-WindowsDriver -Online -ErrorAction Stop)
        foreach($p in $origem) {
            $inf=LerProp $p 'PublishedName'
            if (-not $inf) { $inf=LerProp $p 'Driver' }
            if ($inf -notmatch '^(?i:oem[0-9]+\.inf)$') { continue }
            $pacotes+= [pscustomobject]@{
                Publicado=$inf.ToLowerInvariant()
                Original=(LerProp $p 'OriginalFileName')
                Fornecedor=(LerProp $p 'ProviderName')
                Classe=(LerProp $p 'ClassName')
                Versao=(LerProp $p 'Version')
            }
        }
        if (@($pacotes).Count -eq 0) { throw 'DISM nao retornou pacotes OEM.' }
    } catch {
        # DISM pode exigir elevacao; inventario CIM e limitado
        # aos pacotes associados a dispositivos. A interface sinaliza essa limitacao.
        $script:OrigemInventario='Inventario parcial de dispositivos (CIM): nem todos os pacotes OEM podem aparecer'
        $pacotes=@()
        foreach($p in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)) {
            $inf=LerProp $p 'InfName'
            if ($inf -notmatch '^(?i:oem[0-9]+\.inf)$') { continue }
            $pacotes+= [pscustomobject]@{
                Publicado=$inf.ToLowerInvariant()
                Original=''
                Fornecedor=(LerProp $p 'DriverProviderName')
                Classe=(LerProp $p 'DeviceClass')
                Versao=(LerProp $p 'DriverVersion')
            }
        }
    }
    $porInf=@{}
    foreach($p in $pacotes) { if (-not $porInf.ContainsKey($p.Publicado)) { $porInf[$p.Publicado]=$p } }
    $resultado=@($porInf.Values | Sort-Object -Property Classe,Fornecedor,Publicado)
    if ($resultado.Count -eq 0) { throw 'Nao foi possivel listar drivers de terceiros. Execute a Central como administrador e tente novamente.' }
    return $resultado
}

# Consulta completa e somente-leitura em processo elevado. Impede que a selecao
# de 40 drivers (CIM) seja confundida com os ~194 pacotes do Driver Store.
if ($Inventario) {
    try {
        if (-not (EstaElevado)) { throw 'A consulta completa do Driver Store exige permissao de administrador.' }
        $dados=@(ObterPacotesDrivers)
        if ($script:OrigemInventario -match 'parcial') { throw 'Nao foi possivel consultar o Driver Store completo pelo DISM.' }
        ([pscustomobject]@{Status='OK';Pacotes=$dados;Origem=$script:OrigemInventario}) |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $InventarioArquivo -Encoding UTF8
        exit 0
    } catch {
        ([pscustomobject]@{Status='ERRO';Mensagem=$_.Exception.Message}) |
            ConvertTo-Json | Set-Content -LiteralPath $InventarioArquivo -Encoding UTF8
        exit 1
    }
}

function BackupPacotesDrivers([string]$pasta,[object]$tarefa) {
    if (-not (EstaElevado)) { throw 'Backup de drivers precisa de permissao de administrador.' }
    $destino = Join-Path (Join-Path $pasta '_Temporario') 'Drivers'
    [void](New-Item -ItemType Directory -Path $destino -Force)
    $arquivoLog = Join-Path $pasta 'backup-drivers.log'
    $modo=[string]$tarefa.ModalidadeDrivers
    if ($modo -eq 'Selecionados') {
        $pacotes=@($tarefa.DriversSelecionados)
        if ($pacotes.Count -eq 0) { throw 'Nenhum driver marcado para exportacao.' }
        $ids=@{}
        foreach ($pacote in $pacotes) {
            $id=[string]$pacote.Publicado
            if ($id -notmatch '^(?i:oem[0-9]+\.inf)$') { throw ('Identificador INF invalido: ' + $id) }
            if ($ids.ContainsKey($id)) { throw ('Driver selecionado repetido: ' + $id) }
            $ids[$id]=$true
        }
        $pacotes | Select-Object Publicado,Original,Fornecedor,Classe,Versao |
            Export-Csv -LiteralPath (Join-Path $pasta 'drivers-selecionados.csv') -NoTypeInformation -Encoding UTF8
        EscreverMensagem ('Exportando somente ' + $pacotes.Count + ' pacotes selecionados...')
        $falhas=@(); $indice=0; $auditoria=@()
        foreach($pacote in $pacotes) {
            $indice++
            $id=[string]$pacote.Publicado
            EscreverMensagem ('[' + $indice + '/' + $pacotes.Count + '] Exportando ' + $id + ' - ' + [string]$pacote.Fornecedor)
            # Pasta unica por identificador: torna auditavel o tamanho real de cada pacote.
            $destinoPacote=Join-Path $destino ($id -replace '\.inf$','')
            [void](New-Item -ItemType Directory -Path $destinoPacote -Force)
            & pnputil.exe /export-driver $id $destinoPacote 2>&1 | Out-File -LiteralPath $arquivoLog -Append -Encoding UTF8
            $codigoPacote=[int]$LASTEXITCODE
            $arquivosPacote=@(Get-ChildItem -LiteralPath $destinoPacote -Recurse -File -ErrorAction SilentlyContinue)
            $infsPacote=@($arquivosPacote | Where-Object { $_.Extension -ieq '.inf' })
            $bytesPacote=[long]0
            foreach($arquivo in $arquivosPacote){ $bytesPacote += [long]$arquivo.Length }
            $auditoria += [pscustomobject]@{Publicado=$id;Fornecedor=[string]$pacote.Fornecedor;Classe=[string]$pacote.Classe;Arquivos=$arquivosPacote.Count;Infs=$infsPacote.Count;Bytes=$bytesPacote;MB=[math]::Round($bytesPacote/1MB,2);ExitCode=$codigoPacote}
            EscreverMensagem ('Pacote ' + $id + ': ' + $arquivosPacote.Count + ' arquivos, ' + [math]::Round($bytesPacote/1MB,2) + ' MB')
            if ($codigoPacote -ne 0 -or $infsPacote.Count -eq 0) { $falhas += $id; EscreverMensagem ('ATENCAO: pacote nao exportado corretamente: ' + $id) }
        }
        $auditoria | Export-Csv -LiteralPath (Join-Path $pasta 'pacotes-exportados.csv') -NoTypeInformation -Encoding UTF8
        if ($falhas.Count -gt 0) { throw ('Falha em ' + $falhas.Count + ' pacote(s): ' + ($falhas -join ', ') + '. Verifique backup-drivers.log; a copia temporaria sera mantida.') }
    } else {
        EscreverMensagem 'Exportando TODOS os pacotes de drivers de terceiros com PnPUtil...'
        & pnputil.exe /export-driver '*' $destino 2>&1 | Out-File -LiteralPath $arquivoLog -Encoding UTF8
        $codigo = [int]$LASTEXITCODE
        if ($codigo -ne 0) { throw ('PnPUtil retornou ' + $codigo + '. Consulte backup-drivers.log.') }
    }
    $quantidade = @(Get-ChildItem -LiteralPath $destino -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue).Count
    if ($quantidade -eq 0) { throw 'Nenhum INF foi encontrado apos exportar os drivers.' }
    if ($modo -eq 'Selecionados') {
        $subpastas=@(Get-ChildItem -LiteralPath $destino -Directory -ErrorAction Stop)
        if ($subpastas.Count -ne $pacotes.Count) { throw 'A quantidade de pastas exportadas difere da selecao; backup nao confiavel.' }
        EscreverMensagem ('Pacotes OEM escolhidos/exportados: ' + $pacotes.Count + '; INF nos arquivos: ' + $quantidade)
        return $pacotes.Count
    }
    EscreverMensagem ('Arquivos INF exportados no backup completo: ' + $quantidade)
    return $quantidade
}

# ZIPs ficam ao lado dos relatorios. A origem temporaria so sera removida depois
# de leitura integral, contagem e comparacao SHA-256 de cada entrada extraida.
function PrepararCompactacao {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
}

function CriarZipVerificado([string]$origem,[string]$arquivoZip) {
    if (-not (Test-Path -LiteralPath $origem -PathType Container)) {
        throw ('Pasta temporaria ausente: ' + $origem)
    }
    PrepararCompactacao
    if (Test-Path -LiteralPath $arquivoZip) { throw 'O ZIP de destino ja existe. Nao sera sobrescrito.' }
    $arquivosOrigem = @(Get-ChildItem -LiteralPath $origem -Recurse -File -Force -ErrorAction Stop)
    foreach ($f in $arquivosOrigem) {
        if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('Link simbolico encontrado na copia: ' + $f.FullName + '. Confira o backup.')
        }
    }
    EscreverMensagem ('Compactando ' + [IO.Path]::GetFileName($arquivoZip) + ' (' + $arquivosOrigem.Count + ' arquivos). Aguarde...')
    [IO.Compression.ZipFile]::CreateFromDirectory($origem,$arquivoZip,[IO.Compression.CompressionLevel]::Optimal,$false)
    $zip = $null; $lidos = 0; $total = [long]0
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($arquivoZip)
        foreach ($entrada in $zip.Entries) {
            if (-not $entrada.Name) { continue }
            $relativo = $entrada.FullName.Replace('/',[IO.Path]::DirectorySeparatorChar)
            $arquivoOriginal = [IO.Path]::GetFullPath((Join-Path $origem $relativo))
            $pastaNormalizada = [IO.Path]::GetFullPath($origem).TrimEnd([char]'\') + '\'
            if (-not $arquivoOriginal.StartsWith($pastaNormalizada,[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Entrada inesperada durante a verificacao do ZIP.'
            }
            if (-not (Test-Path -LiteralPath $arquivoOriginal -PathType Leaf)) {
                throw ('Arquivo nao localizado na origem do ZIP: ' + $relativo)
            }
            $item = Get-Item -LiteralPath $arquivoOriginal -ErrorAction Stop
            if ($item.Length -ne $entrada.Length) { throw ('Tamanho divergente no ZIP: ' + $relativo) }
            $stream=$null; $sha=[Security.Cryptography.SHA256]::Create()
            try {
                $stream=$entrada.Open()
                $digest=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')
            } finally {
                if ($null -ne $stream) { $stream.Dispose() }
                $sha.Dispose()
            }
            $esperado=(Get-FileHash -LiteralPath $arquivoOriginal -Algorithm SHA256 -ErrorAction Stop).Hash
            if (-not [string]::Equals($digest,$esperado,[StringComparison]::OrdinalIgnoreCase)) {
                throw ('Verificacao SHA-256 falhou: ' + $relativo)
            }
            $total += [long]$entrada.Length
            $lidos++
            if (($lidos % 150) -eq 0) { EscreverMensagem ('ZIP verificado: ' + $lidos + ' de ' + $arquivosOrigem.Count + ' arquivos') }
        }
    } finally { if ($null -ne $zip) { $zip.Dispose() } }
    if ($lidos -ne $arquivosOrigem.Count) {
        throw ('Quantidade divergente no ZIP: origem=' + $arquivosOrigem.Count + ', ZIP=' + $lidos)
    }
    $hash = (Get-FileHash -LiteralPath $arquivoZip -Algorithm SHA256 -ErrorAction Stop).Hash
    ($hash + ' *' + [IO.Path]::GetFileName($arquivoZip)) |
        Set-Content -LiteralPath ($arquivoZip + '.sha256') -Encoding ASCII
    $tamanho=(Get-Item -LiteralPath $arquivoZip).Length
    EscreverMensagem ('ZIP verificado: ' + $lidos + ' arquivos, ' + [math]::Round($tamanho / 1MB,2) + ' MB.')
    return [pscustomobject]@{ Arquivos=$lidos; Bytes=$tamanho; Sha256=$hash }
}

function ValidarHashZipOpcional([string]$arquivoZip) {
    $hashFile=$arquivoZip + '.sha256'
    if (-not (Test-Path -LiteralPath $hashFile -PathType Leaf)) {
        EscreverMensagem 'Aviso: checksum ao lado do ZIP nao encontrado. Confirme sua origem antes da instalacao.'
        return
    }
    $linha=(Get-Content -LiteralPath $hashFile -Raw -ErrorAction Stop).Trim()
    $esperado=($linha -split '\s+')[0]
    if ($esperado -notmatch '^[a-fA-F0-9]{64}$') { throw 'Arquivo .sha256 invalido.' }
    $atual=(Get-FileHash -LiteralPath $arquivoZip -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($esperado,$atual,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Checksum do Drivers.zip nao corresponde ao arquivo. Nao sera instalado.'
    }
    EscreverMensagem 'SHA-256 do arquivo ZIP confirmado.'
}

function ExtrairZipDriversSeguro([string]$arquivoZip,[string]$destinoTemporario) {
    PrepararCompactacao
    if (-not (Test-Path -LiteralPath $arquivoZip -PathType Leaf)) { throw 'Arquivo ZIP nao encontrado.' }
    if ([IO.Path]::GetExtension($arquivoZip) -ine '.zip') { throw 'Selecione um arquivo .zip.' }
    ValidarHashZipOpcional $arquivoZip
    $arq=$null
    try {
        $arq=[IO.Compression.ZipFile]::OpenRead($arquivoZip)
        $entradas=@($arq.Entries)
        if ($entradas.Count -gt 100000) { throw 'ZIP contem entradas demais para restauracao segura.' }
        $total=[long]0
        foreach($entrada in $entradas) {
            $total += [long]$entrada.Length
            if ($total -gt 60GB) { throw 'ZIP de drivers muito grande para extracao automatica (limite 60 GB).' }
        }
        $driveRaiz=[IO.Path]::GetPathRoot($destinoTemporario)
        $drive=New-Object System.IO.DriveInfo($driveRaiz)
        if ($drive.AvailableFreeSpace -lt ($total + 300MB)) {
            throw ('Espaco insuficiente para extrair drivers. Necessarios aproximadamente ' + [math]::Ceiling(($total + 300MB)/1GB) + ' GB livres na unidade temporaria.')
        }
        [void](New-Item -ItemType Directory -Path $destinoTemporario -Force -ErrorAction Stop)
        $raiz=[IO.Path]::GetFullPath($destinoTemporario).TrimEnd([char]'\') + '\'
        foreach($entrada in $entradas) {
            $nome=[string]$entrada.FullName
            if ([string]::IsNullOrWhiteSpace($nome)) { continue }
            if ([IO.Path]::IsPathRooted($nome) -or $nome.Contains(':') -or
                (($nome -split '[/\\]') -contains '..') -or
                ($nome.StartsWith('\')) -or ($nome.StartsWith('/'))) {
                throw ('Caminho inseguro no ZIP: ' + $nome)
            }
            $tipoUnix = (($entrada.ExternalAttributes -shr 16) -band 61440)
            if ($tipoUnix -eq 40960) { throw ('Link simbolico nao permitido no ZIP: ' + $nome) }
            $final=[IO.Path]::GetFullPath((Join-Path $destinoTemporario ($nome.Replace('/', '\'))))
            if (-not $final.StartsWith($raiz,[StringComparison]::OrdinalIgnoreCase)) {
                throw ('Entrada fora da pasta temporaria: ' + $nome)
            }
            if (-not $entrada.Name) {
                [void](New-Item -ItemType Directory -Path $final -Force)
                continue
            }
            $pai=[IO.Path]::GetDirectoryName($final)
            [void](New-Item -ItemType Directory -Path $pai -Force)
            $origem=$null; $destino=$null
            try {
                $origem=$entrada.Open()
                $destino=[IO.File]::Open($final,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $origem.CopyTo($destino)
            } finally {
                if ($null -ne $destino) { $destino.Dispose() }
                if ($null -ne $origem) { $origem.Dispose() }
            }
            if ((Get-Item -LiteralPath $final).Length -ne $entrada.Length) {
                throw ('Tamanho diferente apos extrair: ' + $nome)
            }
        }
        EscreverMensagem ('ZIP extraido para pasta temporaria: ' + $destinoTemporario)
    } finally { if ($null -ne $arq) { $arq.Dispose() } }
}

function InstalarPacotesINFZip([string]$arquivoZip,[string]$pastaLog) {
    if (-not (EstaElevado)) { throw 'Instalacao de drivers exige permissao de administrador.' }
    # Pasta sob TEMP criada especificamente para esta operacao; o ZIP original nao e alterado.
    $area=Join-Path $env:TEMP 'CentralManutencao'
    [void](New-Item -ItemType Directory -Path $area -Force)
    $extrair=Join-Path $area ('extracao-drivers-' + [guid]::NewGuid().ToString('N'))
    try {
        EscreverMensagem ('Conferindo e extraindo ZIP: ' + $arquivoZip)
        ExtrairZipDriversSeguro $arquivoZip $extrair
        InstalarPacotesINF $extrair $pastaLog
    } finally {
        if (Test-Path -LiteralPath $extrair) {
            try { Remove-Item -LiteralPath $extrair -Force -Recurse -ErrorAction Stop; EscreverMensagem 'Arquivos temporarios da restauracao removidos.' }
            catch { EscreverMensagem ('Nao foi possivel limpar pasta temporaria: ' + $extrair) }
        }
    }
}

function InstalarPacotesINF([string]$pastaInf,[string]$pastaLog) {
    if (-not (EstaElevado)) { throw 'Instalacao de drivers exige permissao de administrador.' }
    if (-not (Test-Path -LiteralPath $pastaInf -PathType Container)) { throw 'Pasta de drivers inexistente.' }
    $infs = @(Get-ChildItem -LiteralPath $pastaInf -Filter '*.inf' -File -Recurse -ErrorAction Stop)
    if ($infs.Count -eq 0) { throw 'Nao ha arquivos INF na pasta selecionada.' }
    $arquivoLog = Join-Path $pastaLog 'instalacao-inf.log'
    EscreverMensagem ('Foram encontrados ' + $infs.Count + ' arquivos INF. O Windows decide quais sao compativeis.')
    # PnPUtil nao usa /force ou /reboot: preserva a classificacao dos drivers e nao reinicia automaticamente.
    $wildcard = Join-Path $pastaInf '*.inf'
    & pnputil.exe /add-driver $wildcard /subdirs /install 2>&1 | Out-File -LiteralPath $arquivoLog -Encoding UTF8
    $codigo = [int]$LASTEXITCODE
    if ($codigo -ne 0) { throw ('PnPUtil retornou ' + $codigo + '. Consulte instalacao-inf.log.') }
    EscreverMensagem 'PnPUtil terminou. Verifique os dispositivos e reinicie somente se o Windows solicitar.'
}

if ($Worker) {
    $tarefa=$null
    $codigoFinal = 0
    try {
        if (-not $JobFile -or -not (Test-Path -LiteralPath $JobFile)) { throw 'Arquivo da operacao nao encontrado.' }
        $tarefa = Get-Content -LiteralPath $JobFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$tarefa.LogPath)) {
            Start-Transcript -LiteralPath ([string]$tarefa.LogPath) -Force -ErrorAction Stop | Out-Null
        }
        if ([string]$tarefa.Operacao -notin @('backup','inf','infzip')) { throw 'Operacao desconhecida.' }
        if ([string]$tarefa.Operacao -eq 'backup') {
            $raiz = [string]$tarefa.Destino
            if (-not (Test-Path -LiteralPath $raiz -PathType Container)) { throw 'Destino nao encontrado. Conecte o HD externo e tente novamente.' }
            $nomePc = ([string]$env:COMPUTERNAME -replace '[^a-zA-Z0-9_-]','_')
            $pasta = Join-Path $raiz ('CentralBackup_' + $nomePc + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
            [void](New-Item -ItemType Directory -Path $pasta -ErrorAction Stop)
            EscreverMensagem ('Backup em: ' + $pasta)
            CriarRelatorioComputador $pasta
            $resultado = [ordered]@{
                Pasta=$pasta; Arquivos='Nao solicitado'; Drivers='Nao solicitado';
                ArquivosZip='Nao solicitado'; DriversZip='Nao solicitado'; Status='EM_EXECUCAO'
            }
            if ([bool]$tarefa.CopiarArquivos) {
                try {
                    $ret = BackupArquivos $tarefa $pasta
                    $resultado.Arquivos = ('Pastas copiadas=' + $ret.Concluidas + ', ausentes=' + $ret.NaoLocalizadas + ', erros=' + $ret.ComErros)
                    if ($ret.ComErros -gt 0 -or $ret.NaoLocalizadas -gt 0) { $codigoFinal = 1 }
                    $estagio = Join-Path (Join-Path $pasta '_Temporario') 'Arquivos'
                    if (Test-Path -LiteralPath $estagio -PathType Container) {
                        $zipPath=Join-Path $pasta 'Arquivos-Usuario.zip'
                        $resZip=CriarZipVerificado $estagio $zipPath
                        $resultado.ArquivosZip = ('OK: ' + $resZip.Arquivos + ' arquivos; ' + [math]::Round($resZip.Bytes/1MB,2) + ' MB')
                        if ($ret.ComErros -eq 0 -and $ret.NaoLocalizadas -eq 0) {
                            Remove-Item -LiteralPath $estagio -Recurse -Force -ErrorAction Stop
                        } else { EscreverMensagem 'Backup parcial de arquivos: copia temporaria mantida para conferencia.' }
                    } else { throw 'Nao foi criada a pasta temporaria de arquivos.' }
                } catch {
                    $zipIncompleto=Join-Path $pasta 'Arquivos-Usuario.zip'
                    if ((Test-Path -LiteralPath $zipIncompleto) -and -not (Test-Path -LiteralPath ($zipIncompleto + '.sha256'))) {
                        Rename-Item -LiteralPath $zipIncompleto -NewName 'Arquivos-Usuario.INCOMPLETO.zip' -ErrorAction SilentlyContinue
                    }
                    $resultado.ArquivosZip='FALHA: ' + $_.Exception.Message
                    EscreverMensagem ('ERRO em Arquivos-Usuario.zip: ' + $_.Exception.Message)
                    $codigoFinal=1
                }
            }
            if ([bool]$tarefa.CopiarDrivers) {
                try {
                    $q=BackupPacotesDrivers $pasta $tarefa
                    $resultado.Drivers = [string]$q + ' pacotes INF exportados'
                    $estagio=Join-Path (Join-Path $pasta '_Temporario') 'Drivers'
                    $zipPath=Join-Path $pasta 'Drivers.zip'
                    $resZip=CriarZipVerificado $estagio $zipPath
                    $resultado.DriversZip = ('OK: ' + $resZip.Arquivos + ' arquivos; ' + [math]::Round($resZip.Bytes/1MB,2) + ' MB')
                    Remove-Item -LiteralPath $estagio -Recurse -Force -ErrorAction Stop
                } catch {
                    $zipIncompleto=Join-Path $pasta 'Drivers.zip'
                    if ((Test-Path -LiteralPath $zipIncompleto) -and -not (Test-Path -LiteralPath ($zipIncompleto + '.sha256'))) {
                        Rename-Item -LiteralPath $zipIncompleto -NewName 'Drivers.INCOMPLETO.zip' -ErrorAction SilentlyContinue
                    }
                    $resultado.Drivers='FALHA OU INCOMPLETO: ' + $_.Exception.Message
                    $resultado.DriversZip='CONFERIR: ' + $_.Exception.Message
                    $codigoFinal=1
                    EscreverMensagem ('ERRO em Drivers.zip: ' + $_.Exception.Message)
                }
            }
            $temporarios=Join-Path $pasta '_Temporario'
            if ((Test-Path -LiteralPath $temporarios) -and
                (@(Get-ChildItem -LiteralPath $temporarios -Force -ErrorAction SilentlyContinue).Count -eq 0)) {
                Remove-Item -LiteralPath $temporarios -Force -ErrorAction SilentlyContinue
            }
            $resultado.Status = if ($codigoFinal -eq 0) { 'COMPACTADO E VERIFICADO; confira os arquivos antes de formatar' }
                else { 'INCOMPLETO OU COM AVISOS; nao formate antes de conferir os logs' }
            $resultado | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $pasta 'resultado-backup.json') -Encoding UTF8
            EscreverMensagem $resultado.Status
            EscreverMensagem ('Backups ZIP e relatorios: ' + $pasta)
        } elseif ([string]$tarefa.Operacao -eq 'infzip') {
            $raizLog = Join-Path $env:TEMP 'CentralManutencao'
            [void](New-Item -ItemType Directory -Path $raizLog -Force)
            InstalarPacotesINFZip ([string]$tarefa.ArquivoZip) $raizLog
            EscreverMensagem ('Log: ' + (Join-Path $raizLog 'instalacao-inf.log'))
        } else {
            $raizLog = Join-Path $env:TEMP 'CentralManutencao'
            [void](New-Item -ItemType Directory -Path $raizLog -Force)
            InstalarPacotesINF ([string]$tarefa.PastaInf) $raizLog
            EscreverMensagem ('Log: ' + (Join-Path $raizLog 'instalacao-inf.log'))
        }
    } catch {
        $codigoFinal = 1
        Write-Host ('ERRO: ' + $_.Exception.Message) -ForegroundColor Red
    }
    Write-Host ''
    Write-Host 'Operacao finalizada. Leia as mensagens e confira os relatorios antes de continuar.'
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    if ($null -ne $tarefa -and -not [string]::IsNullOrWhiteSpace([string]$tarefa.StatusPath)) {
        try {
            ([pscustomobject]@{Codigo=$codigoFinal;Resultado=$(if($codigoFinal -eq 0){'Concluido'}else{'Falha ou backup incompleto'});Data=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')}) |
                ConvertTo-Json | Set-Content -LiteralPath ([string]$tarefa.StatusPath) -Encoding UTF8
        } catch {}
    }
    exit $codigoFinal
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function FonteUI([float]$size,[bool]$negrito=$false) {
    $estilo=[System.Drawing.FontStyle]::Regular
    if ($negrito) { $estilo=[System.Drawing.FontStyle]::Bold }
    return [System.Drawing.Font]::new('Segoe UI',$size,$estilo)
}
function AbrirPasta([string]$titulo) {
    $dialogo = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialogo.Description = $titulo
    $dialogo.ShowNewFolderButton = $true
    if ($dialogo.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialogo.SelectedPath }
    return ''
}
function CaminhoConhecido([string]$nome,[string]$fallback) {
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    try {
        $v=(Get-ItemProperty -Path $reg -Name $nome -ErrorAction Stop).$nome
        if ($v) { return [Environment]::ExpandEnvironmentVariables([string]$v) }
    } catch {}
    return (Join-Path $env:USERPROFILE $fallback)
}
function IniciarTrabalho([object]$tarefa,[bool]$admin) {
    if ($script:execucaoAtiva) { throw 'Ja existe uma operacao em andamento. Aguarde a conclusao.' }
    $pastaTemporaria=Join-Path $env:TEMP 'CentralManutencao'
    [void](New-Item -ItemType Directory -Path $pastaTemporaria -Force)
    $identificador=[guid]::NewGuid().ToString('N')
    $job=Join-Path $pastaTemporaria ('tarefa-' + $identificador + '.json')
    $log=Join-Path $pastaTemporaria ('processo-' + $identificador + '.log')
    $status=Join-Path $pastaTemporaria ('status-' + $identificador + '.json')
    $tarefa | Add-Member -NotePropertyName LogPath -NotePropertyValue $log -Force
    $tarefa | Add-Member -NotePropertyName StatusPath -NotePropertyValue $status -Force
    $tarefa | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $job -Encoding UTF8
    $ps=Join-Path $PSHOME 'powershell.exe'
    $argumentos='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' + $PSCommandPath + '" -Worker -JobFile "' + $job + '"'
    $script:arquivoLogAtivo=$log; $script:arquivoStatusAtivo=$status
    $script:arquivoTarefaAtivo=$job
    $script:ultimoLog=''; $script:txtExecLog.Clear()
    $script:lblExecEstado.Text='Iniciando operacao...'
    $script:lblExecEstado.ForeColor=[System.Drawing.Color]::FromArgb(16,51,92)
    $script:barraExec.Style='Marquee'
    $script:linhaRodape.Height=186; $script:txtExecLog.Visible=$true
    $script:btDetalhesExec.Text='Ocultar detalhes'
    $script:execucaoAtiva=$true
    try {
        if ($admin -and -not (EstaElevado)) {
            # Elevacao por UAC ainda aparece, mas nao cria console para o trabalho.
            $script:procTrabalho=Start-Process -FilePath $ps -ArgumentList $argumentos -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
        } else {
            $script:procTrabalho=Start-Process -FilePath $ps -ArgumentList $argumentos -WindowStyle Hidden -PassThru -ErrorAction Stop
        }
        $script:timerExec.Start()
    } catch {
        $script:execucaoAtiva=$false
        $script:barraExec.Style='Blocks';$script:barraExec.Value=0
        $script:lblExecEstado.Text='Nao foi possivel iniciar: ' + $_.Exception.Message
        throw
    }
}
function AtualizarPainelExec {
    if (-not $script:execucaoAtiva) { return }
    try {
        if (Test-Path -LiteralPath $script:arquivoLogAtivo -PathType Leaf) {
            $linhas=@(Get-Content -LiteralPath $script:arquivoLogAtivo -Tail 100 -ErrorAction Stop |
                Where-Object { $_ -match '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' -or $_ -match '^ERRO:' -or $_ -match '^Operacao finalizada' })
            $conteudo=($linhas -join [Environment]::NewLine)
            if ($conteudo -ne $script:ultimoLog) {
                $script:ultimoLog=$conteudo
                $script:txtExecLog.Text=$conteudo
                $script:txtExecLog.SelectionStart=$script:txtExecLog.TextLength
                $script:txtExecLog.ScrollToCaret()
                $ultima=@($linhas | Where-Object { $_ -match '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' -or $_ -match '^ERRO:' } | Select-Object -Last 1)
                if ($ultima.Count -gt 0) { $script:lblExecEstado.Text=[string]$ultima[0] }
            }
        }
        if ($null -ne $script:procTrabalho -and $script:procTrabalho.HasExited) {
            $script:timerExec.Stop()
            $script:execucaoAtiva=$false
            $script:barraExec.Style='Blocks'
            $script:barraExec.Value=0
            $codigo=$script:procTrabalho.ExitCode
            if (Test-Path -LiteralPath $script:arquivoStatusAtivo) {
                try { $dados=Get-Content -LiteralPath $script:arquivoStatusAtivo -Raw | ConvertFrom-Json; $codigo=[int]$dados.Codigo } catch {}
            }
            if ($codigo -eq 0) {
                $script:lblExecEstado.Text='Operacao finalizada. Confira o ZIP e os relatorios antes de formatar.'
                $script:lblExecEstado.ForeColor=[System.Drawing.Color]::FromArgb(21,119,84)
            } else {
                $script:lblExecEstado.Text='Operacao terminou com falha ou backup incompleto. Consulte os detalhes.'
                $script:lblExecEstado.ForeColor=[System.Drawing.Color]::FromArgb(171,52,41)
            }
            try { Remove-Item -LiteralPath $script:arquivoTarefaAtivo -Force -ErrorAction SilentlyContinue } catch {}
            try { $script:procTrabalho.Dispose() } catch {}
            $script:procTrabalho=$null
        }
    } catch {
        # Uma falha momentanea ao ler um log em escrita nao interrompe o backup.
        $script:lblExecEstado.Text='Operacao em andamento. Atualizando registro...'
    }
}

# As duas visualizacoes usam a mesma tabela de marcacao por INF.
# A agrupada organiza pacotes por classe/identificador, sem supor que a categoria
# garante compatibilidade com um dispositivo especifico.
function GrupoPacoteDriver([object]$pacote) {
    $classe=([string]$pacote.Classe).ToLowerInvariant()
    $detalhe=(([string]$pacote.Original)+' '+([string]$pacote.Fornecedor)).ToLowerInvariant()
    if ($classe -match 'bluetooth') { return 'Bluetooth' }
    if ($classe -match 'display|video') { return 'Video' }
    if ($classe -match 'net') {
        if ($detalhe -match 'wi.?fi|wireless|wlan|netwtw|netwaw|rtwl|qcwlan|bcmwl|802[._-]?11|wdiwifi') { return 'Wi-Fi' }
        return 'Rede e adaptadores'
    }
    if ($classe -match 'audio|media|sound') { return 'Audio' }
    if ($classe -match 'touch|hid|mouse|keyboard|sensor|biometric') { return 'Touch, touchpad e HID' }
    if ($classe -match 'storage|scsi|hdc|diskdrive|volume|nvme') { return 'Armazenamento' }
    if ($classe -match 'usb|controller') { return 'USB e controladores' }
    if ($classe -match 'image|camera') { return 'Camera e imagem' }
    if ($classe -match 'printer|print') { return 'Impressoras' }
    if ($classe -match 'firmware') { return 'Firmware' }
    if ($classe -match 'system|extension|softwarecomponent|chipset|processor|computer') { return 'Sistema e chipset' }
    return 'Outros'
}
function SalvarMarcacaoGrade {
    if ($null -eq $script:gradePacotes -or $script:redesenhandoPacotes) { return }
    [void]$script:gradePacotes.EndEdit()
    foreach($linha in $script:gradePacotes.Rows) {
        if ($null -ne $linha.Tag) {
            $script:pacotesMarcados[[string]$linha.Tag]=[bool]$linha.Cells[0].Value
        }
    }
}
function DesenharPacotesSelecao([switch]$NaoSalvar) {
    if ($null -eq $script:gradePacotes) { return }
    if (-not $NaoSalvar) { SalvarMarcacaoGrade }
    $script:redesenhandoPacotes=$true
    try {
        $script:gradePacotes.Rows.Clear()
        $filtro=$script:filtroPacotes.Text.Trim()
        foreach($p in $script:pacotesInventario) {
            $grupo=GrupoPacoteDriver $p
            $dados=([string]$p.Publicado+' '+[string]$p.Original+' '+[string]$p.Fornecedor+' '+[string]$p.Classe+' '+$grupo)
            if ($filtro -and $dados.IndexOf($filtro,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $indice=$script:gradePacotes.Rows.Add([bool]$script:pacotesMarcados[$p.Publicado],$p.Publicado,$p.Fornecedor,$p.Classe,$p.Original,$p.Versao)
            $script:gradePacotes.Rows[$indice].Tag=[string]$p.Publicado
        }
    } finally { $script:redesenhandoPacotes=$false }
    AtualizarResumoSelecao
}
function AtualizarArvoreMarcacao {
    if ($null -eq $script:arvorePacotes) { return }
    $guardAnterior=$script:redesenhandoArvore
    $script:redesenhandoArvore=$true
    try {
        foreach($raiz in $script:arvorePacotes.Nodes) {
            $categoria=([string]$raiz.Tag).Substring(4)
            $total=0;$ativos=0
            foreach($pacote in $script:pacotesInventario) {
                if ((GrupoPacoteDriver $pacote) -eq $categoria) {
                    $total++
                    if ($script:pacotesMarcados[$pacote.Publicado]) { $ativos++ }
                }
            }
            foreach($filho in $raiz.Nodes) {
                $inf=([string]$filho.Tag).Substring(4)
                $filho.Checked=[bool]$script:pacotesMarcados[$inf]
            }
            $raiz.Checked=($total -gt 0 -and $ativos -eq $total)
            $raiz.Text=($categoria+'  ('+$ativos+'/'+$total+' selecionados)')
            if ($ativos -gt 0 -and $ativos -lt $total) { $raiz.ForeColor=[System.Drawing.Color]::FromArgb(151,98,23) }
            else { $raiz.ForeColor=[System.Drawing.Color]::FromArgb(30,53,79) }
        }
    } finally { $script:redesenhandoArvore=$guardAnterior }
}
function DesenharArvorePacotes {
    if ($null -eq $script:arvorePacotes) { return }
    $filtro=$script:filtroPacotes.Text.Trim()
    $ordem=@('Video','Rede e adaptadores','Wi-Fi','Bluetooth','Audio','Sistema e chipset','Touch, touchpad e HID','USB e controladores','Armazenamento','Camera e imagem','Impressoras','Firmware','Outros')
    $expandidos=@{}
    foreach($n in $script:arvorePacotes.Nodes) { if($n.IsExpanded){$expandidos[[string]$n.Tag]=$true} }
    $script:redesenhandoArvore=$true
    try {
        $script:arvorePacotes.BeginUpdate()
        $script:arvorePacotes.Nodes.Clear()
        foreach($categoria in $ordem) {
            $pacotesGrupo=@($script:pacotesInventario | Where-Object { (GrupoPacoteDriver $_) -eq $categoria })
            if ($pacotesGrupo.Count -eq 0) { continue }
            $visiveis=@()
            foreach($pacote in $pacotesGrupo) {
                $texto=([string]$pacote.Publicado+' '+[string]$pacote.Fornecedor+' '+[string]$pacote.Classe+' '+[string]$pacote.Original+' '+$categoria)
                if (-not $filtro -or $texto.IndexOf($filtro,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $visiveis+=,$pacote }
            }
            if ($visiveis.Count -eq 0) { continue }
            $n=New-Object System.Windows.Forms.TreeNode -ArgumentList $categoria
            $n.Tag='CAT|'+$categoria
            foreach($pacote in $visiveis) {
                $legenda=([string]$pacote.Fornecedor+'  |  '+[string]$pacote.Publicado+'  |  '+[string]$pacote.Versao)
                $filho=New-Object System.Windows.Forms.TreeNode -ArgumentList $legenda
                $filho.Tag='INF|'+[string]$pacote.Publicado
                [void]$n.Nodes.Add($filho)
            }
            [void]$script:arvorePacotes.Nodes.Add($n)
            if ($expandidos.ContainsKey([string]$n.Tag)) { $n.Expand() }
        }
        AtualizarArvoreMarcacao
    } finally {
        $script:arvorePacotes.EndUpdate()
        $script:redesenhandoArvore=$false
    }
    AtualizarResumoSelecao
}
function AtualizarResumoSelecao {
    $q=@($script:pacotesInventario | Where-Object { $script:pacotesMarcados[$_.Publicado] }).Count
    $script:lblMarcados.Text=([string]$q+' de '+[string]$script:pacotesInventario.Count+' pacotes selecionados | Driver Store completo')
}
function AtualizarTelasPacotes {
    DesenharPacotesSelecao -NaoSalvar
    if ($null -ne $script:arvorePacotes) { AtualizarArvoreMarcacao }
    AtualizarResumoSelecao
}
function MarcarPerfilPacotes([string]$perfil) {
    if ($script:modoVisualDrivers -eq 'Avancada') { SalvarMarcacaoGrade }
    $essenciais=@('Video','Rede e adaptadores','Wi-Fi','Bluetooth','Audio','Sistema e chipset','Touch, touchpad e HID','USB e controladores','Armazenamento')
    $conectividade=@('Rede e adaptadores','Wi-Fi','Bluetooth')
    foreach($pacote in $script:pacotesInventario) {
        $grupo=GrupoPacoteDriver $pacote
        switch($perfil) {
            'Tudo' { $script:pacotesMarcados[$pacote.Publicado]=$true }
            'Nada' { $script:pacotesMarcados[$pacote.Publicado]=$false }
            'Essenciais' { $script:pacotesMarcados[$pacote.Publicado]=($essenciais -contains $grupo) }
            'Conectividade' { $script:pacotesMarcados[$pacote.Publicado]=($conectividade -contains $grupo) }
        }
    }
    AtualizarTelasPacotes
}
function AbrirSelecaoDrivers {
    try {
        $script:lblEscolhaDrivers.Text='Consultando pacotes OEM. Aguarde...'
        $script:frm.Refresh()
        if (-not (EstaElevado)) {
            $raizInventario=Join-Path $env:TEMP 'CentralManutencao'
            [void](New-Item -ItemType Directory -Path $raizInventario -Force)
            $arquivoInv=Join-Path $raizInventario ('inventario-' + [guid]::NewGuid().ToString('N') + '.json')
            $psExe=Join-Path $PSHOME 'powershell.exe'
            $argInv='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' + $PSCommandPath + '" -Inventario -InventarioArquivo "' + $arquivoInv + '"'
            # UAC necessario apenas para listar o Driver Store completo, sem instalar nada.
            $processoInv=Start-Process -FilePath $psExe -ArgumentList $argInv -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $arquivoInv)) { throw 'Inventario nao retornado. Confirme a permissao de administrador e tente novamente.' }
            $dadosInv=Get-Content -LiteralPath $arquivoInv -Raw -Encoding UTF8 | ConvertFrom-Json
            Remove-Item -LiteralPath $arquivoInv -Force -ErrorAction SilentlyContinue
            if ([string]$dadosInv.Status -ne 'OK') { throw ('Nao foi possivel listar os pacotes OEM: ' + [string]$dadosInv.Mensagem) }
            $script:pacotesInventario=@($dadosInv.Pacotes)
            $script:OrigemInventario='Driver Store completo (DISM, administrador)'
        } else {
            $script:pacotesInventario=@(ObterPacotesDrivers)
            if ($script:OrigemInventario -match 'parcial') { throw 'A consulta DISM falhou. Nao exibiremos uma lista parcial como se fosse completa.' }
        }
        $script:pacotesMarcados=@{}
        $script:redesenhandoPacotes=$false
        $ja=@{}
        foreach($d in $script:driversSelecionados){$ja[[string]$d.Publicado]=$true}
        foreach($p in $script:pacotesInventario) {
            $script:pacotesMarcados[$p.Publicado]=($script:driversModalidade -eq 'Todos' -or $ja.ContainsKey($p.Publicado))
        }
        $janela=New-Object System.Windows.Forms.Form
        $janela.Text='Selecionar pacotes de drivers para o backup'
        $script:janelaSelecao=$janela
        $janela.ClientSize=[System.Drawing.Size]::new(1030,640)
        $janela.MinimumSize=[System.Drawing.Size]::new(790,480)
        $janela.StartPosition='CenterParent';$janela.Font=FonteUI 9.5
        $janela.BackColor=[System.Drawing.Color]::White
        $janela.AcceptButton=$null
        $l=New-Object System.Windows.Forms.TableLayoutPanel
        $l.Dock='Fill';$l.Padding=[System.Windows.Forms.Padding]::new(16,12,16,12)
        $l.ColumnCount=1;$l.RowCount=7
        foreach($h in @(35,38,40,40,42,0,49)){
            if($h -eq 0){[void]$l.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))}
            else {[void]$l.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,$h))}
        }
        [void]$janela.Controls.Add($l)
        $instrucao=New-Object System.Windows.Forms.Label
        $instrucao.Dock='Fill';$instrucao.Text='Marque apenas os pacotes que deseja guardar. Backup seletivo pode deixar de fora drivers importantes.'
        $instrucao.ForeColor=[System.Drawing.Color]::FromArgb(127,78,22)
        [void]$l.Controls.Add($instrucao,0,0)
        $modoPanel=New-Object System.Windows.Forms.FlowLayoutPanel
        $modoPanel.Dock='Fill';$modoPanel.WrapContents=$false
        $modoTexto=New-Object System.Windows.Forms.Label
        $modoTexto.Text='Visualizacao:';$modoTexto.Width=85;$modoTexto.Height=29;$modoTexto.TextAlign='MiddleLeft'
        $script:comboVisao=New-Object System.Windows.Forms.ComboBox
        $script:comboVisao.DropDownStyle='DropDownList';$script:comboVisao.Width=235
        [void]$script:comboVisao.Items.Add('Simples - categorias')
        [void]$script:comboVisao.Items.Add('Avancada - pacotes INF')
        $script:comboVisao.SelectedIndex=0
        $script:modoVisualDrivers='Simples'
        $orientacao=New-Object System.Windows.Forms.Label
        $orientacao.Text='Expanda as categorias; marque grupos ou pacotes.'
        $orientacao.Width=355;$orientacao.Height=29;$orientacao.TextAlign='MiddleLeft'
        $orientacao.ForeColor=[System.Drawing.Color]::FromArgb(87,106,126)
        [void]$modoPanel.Controls.Add($modoTexto);[void]$modoPanel.Controls.Add($script:comboVisao);[void]$modoPanel.Controls.Add($orientacao)
        [void]$l.Controls.Add($modoPanel,0,1)
        $presets=New-Object System.Windows.Forms.FlowLayoutPanel
        $presets.Dock='Fill';$presets.WrapContents=$false
        $bEssenciais=New-Object System.Windows.Forms.Button;$bEssenciais.Text='Essenciais';$bEssenciais.Width=135
        $bConexao=New-Object System.Windows.Forms.Button;$bConexao.Text='Conectividade';$bConexao.Width=150
        $bTudo=New-Object System.Windows.Forms.Button;$bTudo.Text='Tudo';$bTudo.Width=95
        $bNada=New-Object System.Windows.Forms.Button;$bNada.Text='Nada';$bNada.Width=95
        $presetInfo=New-Object System.Windows.Forms.Label
        $presetInfo.Text='Perfis por classe; revise a selecao.'
        $presetInfo.ForeColor=[System.Drawing.Color]::FromArgb(127,78,22)
        $presetInfo.Width=230;$presetInfo.Height=28;$presetInfo.TextAlign='MiddleLeft'
        foreach($b in @($bEssenciais,$bConexao,$bTudo,$bNada,$presetInfo)){[void]$presets.Controls.Add($b)}
        [void]$l.Controls.Add($presets,0,2)
        $script:filtroPacotes=New-Object System.Windows.Forms.TextBox
        $script:filtroPacotes.Dock='Fill';$script:filtroPacotes.Font=FonteUI 11
        [void]$l.Controls.Add($script:filtroPacotes,0,3)
        $top=New-Object System.Windows.Forms.FlowLayoutPanel
        $top.Dock='Fill'
        $script:lblMarcados=New-Object System.Windows.Forms.Label
        $script:lblMarcados.AutoEllipsis=$true;$script:lblMarcados.Width=500
        $script:lblMarcados.Margin=[System.Windows.Forms.Padding]::new(4,6,0,0)
        [void]$top.Controls.Add($script:lblMarcados)
        [void]$l.Controls.Add($top,0,4)
        $script:gradePacotes=New-Object System.Windows.Forms.DataGridView
        $script:gradePacotes.Dock='Fill';$script:gradePacotes.AllowUserToAddRows=$false
        $script:gradePacotes.AllowUserToDeleteRows=$false
        $script:gradePacotes.RowHeadersVisible=$false
        $script:gradePacotes.AutoSizeColumnsMode='Fill'
        $script:gradePacotes.BackgroundColor=[System.Drawing.Color]::White
        [void]$script:gradePacotes.Columns.Add((New-Object System.Windows.Forms.DataGridViewCheckBoxColumn -Property @{Name='Marcar';HeaderText='Salvar';FillWeight=9}))
        foreach($col in @(@('Publicado',14),@('Fornecedor',27),@('Classe',17),@('Original',23),@('Versao',14))){
            $c=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
            $c.Name=[string]$col[0];$c.HeaderText=[string]$col[0];$c.FillWeight=[float]$col[1]
            $c.ReadOnly=$true
            [void]$script:gradePacotes.Columns.Add($c)
        }
        $script:gradePacotes.Add_CurrentCellDirtyStateChanged({
            if($script:gradePacotes.IsCurrentCellDirty){[void]$script:gradePacotes.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)}
        })
        $script:gradePacotes.Add_CellValueChanged({
            param($sender,$e)
            if (-not $script:redesenhandoPacotes -and $e.ColumnIndex -eq 0 -and $e.RowIndex -ge 0) {
                $linha=$script:gradePacotes.Rows[$e.RowIndex]
                if ($null -ne $linha.Tag) {
                    $script:pacotesMarcados[[string]$linha.Tag]=[bool]$linha.Cells[0].Value
                    AtualizarResumoSelecao
                }
            }
        })
        $script:arvorePacotes=New-Object System.Windows.Forms.TreeView
        $script:arvorePacotes.Dock='Fill';$script:arvorePacotes.CheckBoxes=$true
        $script:arvorePacotes.HideSelection=$false;$script:arvorePacotes.ShowLines=$true
        $script:arvorePacotes.Font=FonteUI 10
        $script:arvorePacotes.ItemHeight=24
        $script:arvorePacotes.BorderStyle='FixedSingle'
        $script:arvorePacotes.Add_AfterCheck({
            param($sender,$e)
            if ($script:redesenhandoArvore -or $e.Action -eq [System.Windows.Forms.TreeViewAction]::Unknown) { return }
            $tag=[string]$e.Node.Tag
            if ($tag.StartsWith('CAT|')) {
                $categoria=$tag.Substring(4)
                foreach($p in $script:pacotesInventario) {
                    if ((GrupoPacoteDriver $p) -eq $categoria) { $script:pacotesMarcados[$p.Publicado]=[bool]$e.Node.Checked }
                }
            } elseif ($tag.StartsWith('INF|')) {
                $script:pacotesMarcados[$tag.Substring(4)]=[bool]$e.Node.Checked
            }
            AtualizarTelasPacotes
        })
        $areaLista=New-Object System.Windows.Forms.Panel
        $areaLista.Dock='Fill'
        [void]$areaLista.Controls.Add($script:gradePacotes)
        [void]$areaLista.Controls.Add($script:arvorePacotes)
        $script:gradePacotes.Visible=$false
        [void]$l.Controls.Add($areaLista,0,5)
        $botoes=New-Object System.Windows.Forms.FlowLayoutPanel;$botoes.Dock='Fill';$botoes.FlowDirection='RightToLeft'
        $btAplicar=New-Object System.Windows.Forms.Button;$btAplicar.Text='Usar selecao no backup';$btAplicar.Width=206;$btAplicar.Height=33
        $btCancelar=New-Object System.Windows.Forms.Button;$btCancelar.Text='Cancelar';$btCancelar.Width=120;$btCancelar.Height=33
        [void]$botoes.Controls.Add($btAplicar);[void]$botoes.Controls.Add($btCancelar)
        [void]$l.Controls.Add($botoes,0,6)
        $script:comboVisao.Add_SelectedIndexChanged({
            if ($script:modoVisualDrivers -eq 'Avancada') { SalvarMarcacaoGrade }
            if ($script:comboVisao.SelectedIndex -eq 1) {
                $script:modoVisualDrivers='Avancada'
                DesenharPacotesSelecao -NaoSalvar
                $script:arvorePacotes.Visible=$false
                $script:gradePacotes.Visible=$true
            } else {
                $script:modoVisualDrivers='Simples'
                DesenharArvorePacotes
                $script:gradePacotes.Visible=$false
                $script:arvorePacotes.Visible=$true
            }
        })
        $script:filtroPacotes.Add_TextChanged({
            if ($script:modoVisualDrivers -eq 'Avancada') { DesenharPacotesSelecao }
            else { DesenharArvorePacotes }
        })
        $bEssenciais.Add_Click({ MarcarPerfilPacotes 'Essenciais' })
        $bConexao.Add_Click({ MarcarPerfilPacotes 'Conectividade' })
        $bTudo.Add_Click({ MarcarPerfilPacotes 'Tudo' })
        $bNada.Add_Click({ MarcarPerfilPacotes 'Nada' })
        $btCancelar.Add_Click({$script:janelaSelecao.DialogResult=[System.Windows.Forms.DialogResult]::Cancel;$script:janelaSelecao.Close()})
        $btAplicar.Add_Click({
            if ($script:modoVisualDrivers -eq 'Avancada') { SalvarMarcacaoGrade }
            $escolhidos=@($script:pacotesInventario | Where-Object { $script:pacotesMarcados[$_.Publicado] })
            if($escolhidos.Count -eq 0){
                [void][System.Windows.Forms.MessageBox]::Show('Selecione pelo menos um pacote, ou cancele para manter backup de todos.','Selecao vazia','OK','Warning')
                return
            }
            if ($escolhidos.Count -eq $script:pacotesInventario.Count -and $script:OrigemInventario -notmatch 'parcial') {
                # Se todos foram marcados numa lista completa, exportacao unica e mais rapida.
                $script:driversModalidade='Todos'
                $script:driversSelecionados=@()
                $script:lblEscolhaDrivers.Text='Todos os pacotes OEM (backup completo)'
            } else {
                $script:driversSelecionados=$escolhidos
                $script:driversModalidade='Selecionados'
                $script:lblEscolhaDrivers.Text=('Selecao personalizada: '+$escolhidos.Count+' pacote(s) OEM')
            }
            $script:janelaSelecao.DialogResult=[System.Windows.Forms.DialogResult]::OK;$script:janelaSelecao.Close()
        })
        DesenharPacotesSelecao -NaoSalvar
        DesenharArvorePacotes
        [void]$janela.ShowDialog($script:frm)
        $janela.Dispose()
        if($script:driversModalidade -eq 'Todos'){$script:lblEscolhaDrivers.Text='Todos os pacotes OEM (padrao)'}
    } catch {
        $script:lblEscolhaDrivers.Text='Nao foi possivel listar pacotes. Backup completo permanece disponivel.'
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Listar drivers','OK','Error')
    }
}

$frm = New-Object System.Windows.Forms.Form
$frm.Text='Central de Aplicativos - Manutencao e Drivers | v8.6.5.1 local'
$frm.ClientSize=[System.Drawing.Size]::new(980,720)
$frm.MinimumSize=[System.Drawing.Size]::new(780,600)
$frm.StartPosition='CenterScreen'
$frm.BackColor=[System.Drawing.Color]::FromArgb(244,247,252)
$frm.Font=FonteUI 9.5
$frm.AutoScaleMode=[System.Windows.Forms.AutoScaleMode]::Dpi
$tabs=New-Object System.Windows.Forms.TabControl
$tabs.Dock='Fill'
$tabs.Font=FonteUI 10 $true
$raizInterface=New-Object System.Windows.Forms.TableLayoutPanel
$raizInterface.Dock='Fill';$raizInterface.RowCount=2;$raizInterface.ColumnCount=1
$raizInterface.Margin=[System.Windows.Forms.Padding]::new(0)
[void]$raizInterface.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
$script:linhaRodape=[System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,66)
[void]$raizInterface.RowStyles.Add($script:linhaRodape)
[void]$raizInterface.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$frm.Controls.Add($raizInterface)
[void]$raizInterface.Controls.Add($tabs,0,0)
$tbBackup=New-Object System.Windows.Forms.TabPage
$tbBackup.Text='Backup antes de formatar'
$tbBackup.BackColor=[System.Drawing.Color]::White
$tbDriver=New-Object System.Windows.Forms.TabPage
$tbDriver.Text='Drivers e diagnostico'
$tbDriver.BackColor=[System.Drawing.Color]::White
[void]$tabs.TabPages.Add($tbBackup)
[void]$tabs.TabPages.Add($tbDriver)
# Painel comum das abas, sem janelas pretas do PowerShell durante tarefas.
$script:execucaoAtiva=$false
$script:procTrabalho=$null
$script:arquivoLogAtivo='';$script:arquivoStatusAtivo='';$script:ultimoLog=''
$script:painelExec=New-Object System.Windows.Forms.Panel
$script:painelExec.Dock='Fill';$script:painelExec.Margin=[System.Windows.Forms.Padding]::new(0)
$script:painelExec.BackColor=[System.Drawing.Color]::FromArgb(240,245,251)
$linhaExec=New-Object System.Windows.Forms.TableLayoutPanel
$linhaExec.Dock='Top';$linhaExec.Height=36;$linhaExec.ColumnCount=4
[void]$linhaExec.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
foreach($w in @(124,90,88)){[void]$linhaExec.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,$w))}
$script:lblExecEstado=New-Object System.Windows.Forms.Label
$script:lblExecEstado.Text='Pronto. Escolha uma operacao para iniciar.'
$script:lblExecEstado.Dock='Fill';$script:lblExecEstado.TextAlign='MiddleLeft'
$script:lblExecEstado.Padding=[System.Windows.Forms.Padding]::new(12,0,0,0)
$script:lblExecEstado.AutoEllipsis=$true
$script:btDetalhesExec=New-Object System.Windows.Forms.Button
$script:btDetalhesExec.Text='Mostrar detalhes';$script:btDetalhesExec.Dock='Fill'
$btCopiarExec=New-Object System.Windows.Forms.Button
$btCopiarExec.Text='Copiar log';$btCopiarExec.Dock='Fill'
$btSalvarExec=New-Object System.Windows.Forms.Button
$btSalvarExec.Text='Salvar log';$btSalvarExec.Dock='Fill'
$linhaExec.Controls.Add($script:lblExecEstado,0,0)
$linhaExec.Controls.Add($script:btDetalhesExec,1,0)
$linhaExec.Controls.Add($btCopiarExec,2,0)
$linhaExec.Controls.Add($btSalvarExec,3,0)
$script:barraExec=New-Object System.Windows.Forms.ProgressBar
$script:barraExec.Dock='Top';$script:barraExec.Height=8
$script:barraExec.Style='Blocks';$script:barraExec.Maximum=100
$script:txtExecLog=New-Object System.Windows.Forms.TextBox
$script:txtExecLog.Dock='Fill';$script:txtExecLog.Multiline=$true
$script:txtExecLog.ReadOnly=$true;$script:txtExecLog.ScrollBars='Vertical'
$script:txtExecLog.Font=[System.Drawing.Font]::new('Consolas',9)
$script:txtExecLog.BackColor=[System.Drawing.Color]::FromArgb(250,252,255)
$script:txtExecLog.Visible=$false
# Tres faixas independentes: barra de estado, atividade e texto.
# Evita tambem que os detalhes do log cubram os controles do rodape.
$estruturaLog=New-Object System.Windows.Forms.TableLayoutPanel
$estruturaLog.Dock='Fill';$estruturaLog.ColumnCount=1;$estruturaLog.RowCount=3
[void]$estruturaLog.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,36))
[void]$estruturaLog.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,8))
[void]$estruturaLog.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$estruturaLog.Controls.Add($linhaExec,0,0)
[void]$estruturaLog.Controls.Add($script:barraExec,0,1)
[void]$estruturaLog.Controls.Add($script:txtExecLog,0,2)
[void]$script:painelExec.Controls.Add($estruturaLog)
[void]$raizInterface.Controls.Add($script:painelExec,0,1)
$script:timerExec=New-Object System.Windows.Forms.Timer
$script:timerExec.Interval=550
$script:timerExec.Add_Tick({ AtualizarPainelExec })
$script:btDetalhesExec.Add_Click({
    if ($script:linhaRodape.Height -lt 100) {
        $script:linhaRodape.Height=186
        $script:txtExecLog.Visible=$true
        $script:btDetalhesExec.Text='Ocultar detalhes'
    } else {
        $script:linhaRodape.Height=66
        $script:txtExecLog.Visible=$false
        $script:btDetalhesExec.Text='Mostrar detalhes'
    }
})
$btCopiarExec.Add_Click({
    if ($script:txtExecLog.Text) { [System.Windows.Forms.Clipboard]::SetText($script:txtExecLog.Text) }
})
$btSalvarExec.Add_Click({
    if (-not $script:arquivoLogAtivo -or -not (Test-Path -LiteralPath $script:arquivoLogAtivo)) {
        [void][System.Windows.Forms.MessageBox]::Show('Ainda nao ha log de operacao para salvar.','Log','OK','Information')
        return
    }
    $dlg=New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter='Arquivo texto (*.txt)|*.txt';$dlg.FileName='central-manutencao-log.txt'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Copy-Item -LiteralPath $script:arquivoLogAtivo -Destination $dlg.FileName -Force
    }
})
$frm.Add_FormClosing({
    param($sender,$e)
    if ($script:execucaoAtiva) {
        $escolha=[System.Windows.Forms.MessageBox]::Show('Existe uma operacao em andamento. Fechar esta janela nao interrompe o trabalho, mas voce nao vera a conclusao. Manter aberta?','Operacao em andamento','YesNo','Warning')
        if ($escolha -eq [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel=$true }
    }
})


# Backup: tela compacta; o destino e o conteudo ficam visiveis sem um botao gigante.
$layoutB=New-Object System.Windows.Forms.TableLayoutPanel
$layoutB.Dock='Fill'
$layoutB.Padding=[System.Windows.Forms.Padding]::new(25,18,25,14)
$layoutB.ColumnCount=1
$layoutB.RowCount=13
# A ultima linha absorve o espaco livre para manter o botao de backup compacto.
foreach($h in @(45,35,26,44,31,32,36,54,42,49,73,56,0)) {
    if ($h -eq 0) { [void]$layoutB.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100)) }
    else { [void]$layoutB.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,$h)) }
}
$layoutB.AutoScroll=$true
$tbBackup.Controls.Add($layoutB)
$lblB=New-Object System.Windows.Forms.Label
$lblB.Text='Backup antes da formatacao'
$lblB.Font=FonteUI 16 $true
$lblB.Dock='Fill';$lblB.ForeColor=[System.Drawing.Color]::FromArgb(16,51,92)
$layoutB.Controls.Add($lblB,0,0)
$infoB=New-Object System.Windows.Forms.Label
$infoB.Text='Crie dois ZIPs separados (arquivos e drivers) em um HD externo, antes de reinstalar o Windows.'
$infoB.Dock='Fill';$infoB.ForeColor=[System.Drawing.Color]::FromArgb(86,102,122)
$layoutB.Controls.Add($infoB,0,1)
$lblDestino=New-Object System.Windows.Forms.Label
$lblDestino.Text='1. Onde salvar'
$lblDestino.Dock='Fill';$lblDestino.Font=FonteUI 10 $true
$lblDestino.ForeColor=[System.Drawing.Color]::FromArgb(16,51,92)
$layoutB.Controls.Add($lblDestino,0,2)
$destPanel=New-Object System.Windows.Forms.TableLayoutPanel
$destPanel.Dock='Fill';$destPanel.ColumnCount=2
[void]$destPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,75))
[void]$destPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,25))
$txtDest=New-Object System.Windows.Forms.TextBox
$txtDest.Dock='Fill';$txtDest.ReadOnly=$true
$txtDest.Font=FonteUI 9.7
$txtDest.Margin=[System.Windows.Forms.Padding]::new(0,7,9,8)
$btDest=New-Object System.Windows.Forms.Button
$btDest.Text='Selecionar HD / pasta';$btDest.Dock='Fill'
$btDest.Margin=[System.Windows.Forms.Padding]::new(0,3,0,4)
$destPanel.Controls.Add($txtDest,0,0);$destPanel.Controls.Add($btDest,1,0)
$layoutB.Controls.Add($destPanel,0,3)
$lblDestinoEstado=New-Object System.Windows.Forms.Label
$lblDestinoEstado.Text='Nenhum destino selecionado. Prefira um HD externo ou pendrive.'
$lblDestinoEstado.Dock='Fill'
$lblDestinoEstado.ForeColor=[System.Drawing.Color]::FromArgb(86,102,122)
$lblDestinoEstado.Font=FonteUI 8.9
$layoutB.Controls.Add($lblDestinoEstado,0,4)
$btDest.Add_Click({
    $v=AbrirPasta 'Escolha a pasta do HD externo ou outro destino para os backups'
    if ($v) {
        $txtDest.Text=$v
        $sistema=[IO.Path]::GetPathRoot($env:SystemRoot)
        $raiz=[IO.Path]::GetPathRoot($v)
        if ([string]::Equals($sistema,$raiz,[StringComparison]::OrdinalIgnoreCase)) {
            $lblDestinoEstado.Text='ATENCAO: destino na unidade do Windows. Copie para HD externo antes de formatar.'
            $lblDestinoEstado.ForeColor=[System.Drawing.Color]::FromArgb(162,91,18)
        } else {
            $lblDestinoEstado.Text='Destino diferente da unidade do Windows. Confira se o HD correto esta conectado.'
            $lblDestinoEstado.ForeColor=[System.Drawing.Color]::FromArgb(20,116,89)
        }
    }
})
$lblSelecao=New-Object System.Windows.Forms.Label
$lblSelecao.Text='2. O que deseja salvar'
$lblSelecao.Font=FonteUI 10 $true
$lblSelecao.ForeColor=[System.Drawing.Color]::FromArgb(16,51,92)
$lblSelecao.Dock='Fill'
$layoutB.Controls.Add($lblSelecao,0,5)
$opcoes=New-Object System.Windows.Forms.FlowLayoutPanel
$opcoes.Dock='Fill';$opcoes.WrapContents=$false
$chkArquivos=New-Object System.Windows.Forms.CheckBox
$chkArquivos.Text='Arquivos do usuario';$chkArquivos.Width=200;$chkArquivos.Checked=$true
$chkDrivers=New-Object System.Windows.Forms.CheckBox
$chkDrivers.Text='Drivers de terceiros';$chkDrivers.Width=215;$chkDrivers.Checked=$true
[void]$opcoes.Controls.Add($chkArquivos);[void]$opcoes.Controls.Add($chkDrivers)
$layoutB.Controls.Add($opcoes,0,6)
$pastasPanel=New-Object System.Windows.Forms.FlowLayoutPanel
$pastasPanel.Dock='Fill';$pastasPanel.WrapContents=$true
$pastasPanel.Padding=[System.Windows.Forms.Padding]::new(0,3,0,0)
$fontes=@(
    @{Nome='Area de Trabalho';Chave='Desktop';Reg='Desktop';Dir='Desktop';Ativo=$true},
    @{Nome='Documentos';Chave='Documents';Reg='Personal';Dir='Documents';Ativo=$true},
    @{Nome='Downloads';Chave='Downloads';Reg='{374DE290-123F-4565-9164-39C4925E467B}';Dir='Downloads';Ativo=$true},
    @{Nome='Imagens';Chave='Pictures';Reg='My Pictures';Dir='Pictures';Ativo=$true},
    @{Nome='Videos';Chave='Videos';Reg='My Video';Dir='Videos';Ativo=$false},
    @{Nome='Musicas';Chave='Music';Reg='My Music';Dir='Music';Ativo=$false}
)
$seletores=@()
foreach($f in $fontes) {
    $c=New-Object System.Windows.Forms.CheckBox
    $c.Text=[string]$f.Nome
    $c.Width=136;$c.Checked=[bool]$f.Ativo
    $c.Tag=$f
    $seletores+=,$c
    [void]$pastasPanel.Controls.Add($c)
}
$layoutB.Controls.Add($pastasPanel,0,7)
# Opcao para nao exportar pacotes desnecessarios.
$script:driversModalidade='Todos'
$script:driversSelecionados=@()
$driverPanel=New-Object System.Windows.Forms.TableLayoutPanel
$driverPanel.Dock='Fill';$driverPanel.ColumnCount=3
[void]$driverPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,114))
[void]$driverPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,202))
[void]$driverPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
$lblDriversSecao=New-Object System.Windows.Forms.Label
$lblDriversSecao.Text='Drivers';$lblDriversSecao.Dock='Fill';$lblDriversSecao.TextAlign='MiddleLeft'
$lblDriversSecao.Font=FonteUI 9 $true
$btEscolherDrivers=New-Object System.Windows.Forms.Button
$btEscolherDrivers.Text='Listar / escolher';$btEscolherDrivers.Dock='Fill'
$btEscolherDrivers.Margin=[System.Windows.Forms.Padding]::new(0,3,10,4)
$lblEscolhaDrivers=New-Object System.Windows.Forms.Label
$lblEscolhaDrivers.Text='Todos os pacotes OEM (padrao)'
$lblEscolhaDrivers.AutoEllipsis=$true;$lblEscolhaDrivers.Dock='Fill'
$lblEscolhaDrivers.TextAlign='MiddleLeft'
[void]$driverPanel.Controls.Add($lblDriversSecao,0,0)
[void]$driverPanel.Controls.Add($btEscolherDrivers,1,0)
[void]$driverPanel.Controls.Add($lblEscolhaDrivers,2,0)
$layoutB.Controls.Add($driverPanel,0,9)
$chkDrivers.Add_CheckedChanged({ $btEscolherDrivers.Enabled=$chkDrivers.Checked })
$btEscolherDrivers.Add_Click({ AbrirSelecaoDrivers })

$extraPanel=New-Object System.Windows.Forms.TableLayoutPanel
$extraPanel.Dock='Fill';$extraPanel.ColumnCount=3
[void]$extraPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,114))
[void]$extraPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,202))
[void]$extraPanel.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
$lblExtraSecao=New-Object System.Windows.Forms.Label
$lblExtraSecao.Text='Arquivos';$lblExtraSecao.Font=FonteUI 9 $true
$lblExtraSecao.Dock='Fill';$lblExtraSecao.TextAlign='MiddleLeft'
$btExtra=New-Object System.Windows.Forms.Button
$btExtra.Text='Adicionar pasta';$btExtra.Dock='Fill'
$btExtra.Margin=[System.Windows.Forms.Padding]::new(0,3,10,4)
$lblExtra=New-Object System.Windows.Forms.Label
$lblExtra.Text='Nenhuma pasta adicional';$lblExtra.AutoEllipsis=$true
$lblExtra.Dock='Fill';$lblExtra.TextAlign='MiddleLeft'
[void]$extraPanel.Controls.Add($lblExtraSecao,0,0)
[void]$extraPanel.Controls.Add($btExtra,1,0)
[void]$extraPanel.Controls.Add($lblExtra,2,0)
$layoutB.Controls.Add($extraPanel,0,8)
$script:outraPasta=''
$btExtra.Add_Click({ $v=AbrirPasta 'Escolha uma pasta adicional com arquivos que precisa copiar'; if ($v) { $script:outraPasta=$v; $lblExtra.Text=$v } })
$chkArquivos.Add_CheckedChanged({
    foreach($c in $seletores) { $c.Enabled=$chkArquivos.Checked }
    $btExtra.Enabled=$chkArquivos.Checked
})
$avisosB=New-Object System.Windows.Forms.Label
$avisosB.Text='ANTES DE FORMATAR: confira os ZIPs e os relatorios. Ao selecionar poucos drivers, outros podem faltar apos a formatacao. O ZIP nao tem senha; proteja o HD. E necessario espaco extra durante a copia. O backup nao inclui programas, senhas, certificados, emails locais ou arquivos apenas na nuvem.'
$avisosB.Dock='Fill';$avisosB.ForeColor=[System.Drawing.Color]::FromArgb(136,92,32)
$avisosB.Font=FonteUI 9
$layoutB.Controls.Add($avisosB,0,10)
$acoesB=New-Object System.Windows.Forms.FlowLayoutPanel
$acoesB.Dock='Fill';$acoesB.WrapContents=$false
$acoesB.Padding=[System.Windows.Forms.Padding]::new(0,4,0,0)
$btBackup=New-Object System.Windows.Forms.Button
$btBackup.Text='Iniciar backup'
$btBackup.Width=185;$btBackup.Height=39
$btBackup.BackColor=[System.Drawing.Color]::FromArgb(19,99,185)
$btBackup.ForeColor=[System.Drawing.Color]::White
$btBackup.FlatStyle='Flat';$btBackup.Font=FonteUI 10 $true
$btAbrirDestino=New-Object System.Windows.Forms.Button
$btAbrirDestino.Text='Abrir pasta de destino'
$btAbrirDestino.Width=194;$btAbrirDestino.Height=39
$btAbrirDestino.Margin=[System.Windows.Forms.Padding]::new(12,0,0,0)
[void]$acoesB.Controls.Add($btBackup)
[void]$acoesB.Controls.Add($btAbrirDestino)
$layoutB.Controls.Add($acoesB,0,11)
$btAbrirDestino.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($txtDest.Text) -and (Test-Path -LiteralPath $txtDest.Text -PathType Container)) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $txtDest.Text + '"')
    } else {
        [void][System.Windows.Forms.MessageBox]::Show('Escolha uma pasta de destino primeiro.','Destino','OK','Information')
    }
})
$btBackup.Add_Click({
    try {
        if (-not $txtDest.Text -or -not (Test-Path -LiteralPath $txtDest.Text -PathType Container)) { throw 'Selecione uma pasta de destino valida.' }
        if (-not $chkArquivos.Checked -and -not $chkDrivers.Checked) { throw 'Selecione arquivos ou drivers.' }
        $lista=@()
        if ($chkArquivos.Checked) {
            foreach($c in $seletores) {
                if ($c.Checked) {
                    $f=$c.Tag
                    $lista+=@{Nome=[string]$f.Chave;Caminho=(CaminhoConhecido ([string]$f.Reg) ([string]$f.Dir))}
                }
            }
            if ($script:outraPasta) { $lista+=@{Nome='PastaAdicional';Caminho=$script:outraPasta} }
            if ($lista.Count -eq 0) { throw 'Marque pelo menos uma pasta de arquivos.' }
        }
        $sistema=[IO.Path]::GetPathRoot($env:SystemRoot)
        $destRaiz=[IO.Path]::GetPathRoot($txtDest.Text)
        $alerta='O backup sera gravado em: ' + $txtDest.Text + [Environment]::NewLine + [Environment]::NewLine
        if ($destRaiz -eq $sistema) { $alerta+='ATENCAO: o destino esta na unidade do Windows. Prefira HD externo e copie para fora do computador antes de formatar.' + [Environment]::NewLine + [Environment]::NewLine }
        $alerta+='Arquivos: ' + [bool]$chkArquivos.Checked + ' | Drivers: ' + [bool]$chkDrivers.Checked + [Environment]::NewLine
        if ($chkDrivers.Checked) {
            $textoSelecao=if($script:driversModalidade -eq 'Todos'){'TODOS os pacotes OEM'}else{[string]$script:driversSelecionados.Count + ' pacotes escolhidos'}
            $alerta+='Selecao dos drivers: '+$textoSelecao+[Environment]::NewLine
        }
        $alerta+='Serão criados Drivers.zip e/ou Arquivos-Usuario.zip, mais relatórios e checksums SHA-256. É necessário espaço extra para cópias temporárias. O ZIP não tem senha. Confirmar?'
        if ([System.Windows.Forms.MessageBox]::Show($alerta,'Confirmar backup','YesNo','Warning') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $tarefa=[pscustomobject]@{Operacao='backup';Destino=$txtDest.Text;CopiarArquivos=[bool]$chkArquivos.Checked;CopiarDrivers=[bool]$chkDrivers.Checked;Fontes=$lista;ModalidadeDrivers=$script:driversModalidade;DriversSelecionados=@($script:driversSelecionados)}
        IniciarTrabalho $tarefa ([bool]$chkDrivers.Checked)
    } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Backup','OK','Error') }
})

# Aba de diagnostico: nenhum comando modifica dispositivos ao consultar.
$layoutD=New-Object System.Windows.Forms.TableLayoutPanel
$layoutD.Dock='Fill';$layoutD.Padding=[System.Windows.Forms.Padding]::new(20,15,20,15)
$layoutD.ColumnCount=1;$layoutD.RowCount=6
foreach($h in @(44,43,42,42,0,64)) {
    if($h -eq 0){ [void]$layoutD.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100)) }
    else { [void]$layoutD.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,$h)) }
}
$tbDriver.Controls.Add($layoutD)
$ttlD=New-Object System.Windows.Forms.Label
$ttlD.Text='Drivers e dispositivos'
$ttlD.Font=FonteUI 16 $true;$ttlD.ForeColor=[System.Drawing.Color]::FromArgb(16,51,92);$ttlD.Dock='Fill'
$layoutD.Controls.Add($ttlD,0,0)
$subD=New-Object System.Windows.Forms.Label
$subD.Text='Localize problemas, consulte o Windows Update ou instale pacotes INF ja obtidos de fabricantes confiaveis.'
$subD.Dock='Fill';$subD.ForeColor=[System.Drawing.Color]::FromArgb(90,105,125)
$layoutD.Controls.Add($subD,0,1)
$btLinha1=New-Object System.Windows.Forms.FlowLayoutPanel
$btLinha1.Dock='Fill'
$btVerificar=New-Object System.Windows.Forms.Button
$btVerificar.Text='Verificar dispositivos';$btVerificar.Width=175
$btUpdate=New-Object System.Windows.Forms.Button
$btUpdate.Text='Windows Update';$btUpdate.Width=148
$btDeviceManager=New-Object System.Windows.Forms.Button
$btDeviceManager.Text='Gerenciador de Dispositivos';$btDeviceManager.Width=216
foreach($b in @($btVerificar,$btUpdate,$btDeviceManager)){[void]$btLinha1.Controls.Add($b)}
$layoutD.Controls.Add($btLinha1,0,2)
$lblD=New-Object System.Windows.Forms.Label
$lblD.Text='Clique em Verificar dispositivos para listar o status atual.'
$lblD.Dock='Fill';$lblD.ForeColor=[System.Drawing.Color]::FromArgb(76,93,114)
$layoutD.Controls.Add($lblD,0,3)
$grade=New-Object System.Windows.Forms.DataGridView
$grade.Dock='Fill';$grade.ReadOnly=$true;$grade.AllowUserToAddRows=$false
$grade.AllowUserToDeleteRows=$false;$grade.AutoSizeColumnsMode='Fill';$grade.RowHeadersVisible=$false
$grade.SelectionMode='FullRowSelect';$grade.BackgroundColor=[System.Drawing.Color]::White
$grade.ColumnCount=3
$grade.Columns[0].Name='Dispositivo';$grade.Columns[0].FillWeight=60
$grade.Columns[1].Name='Classe';$grade.Columns[1].FillWeight=20
$grade.Columns[2].Name='Status';$grade.Columns[2].FillWeight=20
$layoutD.Controls.Add($grade,0,4)
$btLinha2=New-Object System.Windows.Forms.FlowLayoutPanel
$btLinha2.Dock='Fill'
$btInf=New-Object System.Windows.Forms.Button
$btInf.Text='Instalar pasta INF';$btInf.Width=178
$btInf.BackColor=[System.Drawing.Color]::FromArgb(19,99,185)
$btInf.ForeColor=[System.Drawing.Color]::White
$btInf.FlatStyle='Flat'
$btOpcionais=New-Object System.Windows.Forms.Button
$btOpcionais.Text='Atualizacoes opcionais';$btOpcionais.Width=175
$btZip=New-Object System.Windows.Forms.Button
$btZip.Text='Restaurar Drivers.zip';$btZip.Width=185
foreach($b in @($btInf,$btZip,$btOpcionais)){[void]$btLinha2.Controls.Add($b)}
$layoutD.Controls.Add($btLinha2,0,5)
$btVerificar.Add_Click({
    $grade.Rows.Clear();$lblD.Text='Consultando dispositivos...'
    try {
        $todos=@(Get-PnpDevice -PresentOnly -ErrorAction Stop | Sort-Object Status,Class,FriendlyName)
        $erros=0
        foreach($dev in $todos) {
            $status=[string]$dev.Status
            if($status -ne 'OK'){$erros++}
            $nome=if($dev.FriendlyName){[string]$dev.FriendlyName}else{'Dispositivo sem nome'}
            [void]$grade.Rows.Add($nome,[string]$dev.Class,$status)
        }
        $lblD.Text=($todos.Count.ToString() + ' dispositivos presentes | ' + $erros + ' com status diferente de OK. Status nao significa necessariamente driver ausente.')
    } catch { $lblD.Text='Nao foi possivel consultar dispositivos: ' + $_.Exception.Message }
})
$btUpdate.Add_Click({ try { Start-Process 'ms-settings:windowsupdate' } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Windows Update') } })
$btOpcionais.Add_Click({ try { Start-Process 'ms-settings:windowsupdate-optionalupdates' } catch { Start-Process 'ms-settings:windowsupdate' } })
$btDeviceManager.Add_Click({ Start-Process 'devmgmt.msc' })
# Permite selecionar diretamente Drivers.zip; nunca instala ao escolher o arquivo.
$btZip.Add_Click({
    try {
        $dlg=New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title='Selecione Drivers.zip criado pelo backup ou ZIP confiavel do fabricante'
        $dlg.Filter='Arquivos ZIP (*.zip)|*.zip'
        $dlg.Multiselect=$false
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $selecionado=$dlg.FileName
        PrepararCompactacao
        $arq=$null; $quant=0
        try {
            $arq=[IO.Compression.ZipFile]::OpenRead($selecionado)
            $quant=@($arq.Entries | Where-Object { $_.Name -match '(?i)\.inf$' }).Count
        } finally { if ($null -ne $arq) { $arq.Dispose() } }
        if ($quant -eq 0) { throw 'Nao foram encontrados arquivos INF no ZIP. Escolha Drivers.zip ou outro pacote confiavel.' }
        $msg='ZIP: ' + $selecionado + [Environment]::NewLine +
            'Arquivos INF encontrados: ' + $quant + [Environment]::NewLine +
            [Environment]::NewLine + 'O ZIP sera verificado e extraido temporariamente antes de tentar instalar os drivers compativeis. Pode exigir espaco livre e permissao de administrador. Use apenas backups e fornecedores confiaveis. Continuar?'
        if ([System.Windows.Forms.MessageBox]::Show($msg,'Confirmar restauracao via ZIP','YesNo','Warning') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        IniciarTrabalho ([pscustomobject]@{Operacao='infzip';ArquivoZip=$selecionado}) $true
    } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Drivers.zip','OK','Error') }
})
$btInf.Add_Click({
    try {
        $pasta=AbrirPasta 'Selecione a pasta INF do fabricante ou a pasta Drivers de um backup'
        if (-not $pasta) { return }
        $arqs=@(Get-ChildItem -LiteralPath $pasta -Recurse -File -Filter '*.inf' -ErrorAction Stop)
        if($arqs.Count -eq 0) { throw 'A pasta nao contem arquivos INF.' }
        $msg='Pacotes INF encontrados: ' + $arqs.Count + [Environment]::NewLine + 'Pasta: ' + $pasta + [Environment]::NewLine + [Environment]::NewLine + 'Use somente drivers de origem confiavel e adequados ao hardware. O Windows aplica verificacoes de assinatura e compatibilidade. Nao sera forcada instalacao nem reinicio. Continuar?'
        if ([System.Windows.Forms.MessageBox]::Show($msg,'Confirmar instalacao de drivers','YesNo','Warning') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        IniciarTrabalho ([pscustomobject]@{Operacao='inf';PastaInf=$pasta}) $true
    } catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Instalar INF','OK','Error') }
})

try { [void]$frm.ShowDialog() }
finally { $frm.Dispose() }
