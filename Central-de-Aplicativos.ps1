# Central de Aplicativos v8.5.3 - refinamento final local para Windows 10/11
# Requer WinGet para baixar e instalar. Sem site, sem dominio, sem servidor.
# O TI deve conferir scripts e licencas antes de executar. Nao altera a politica de execucao global.
param(
    [switch]$Worker,
    [ValidateSet('install','download','upgrade','inventory')][string]$Operacao = 'install',
    [string]$PacoteId = '', [string]$TipoPacote = '', [string]$ArquiteturaPacote = '',
    [string]$Saida = '', [string]$Resultado = '', [string]$PastaDownload = ''
)

# --- Processo separado: instalacao/download com log e codigo de saida ---
if ($Worker) {
    # A verificacao do inventario ocorre em processo independente da interface.
    if ($Operacao -eq 'inventory') {
        try {
            if (-not $Saida -or -not $Resultado) { throw 'Caminhos de inventario ausentes.' }
            $wg = Get-Command winget.exe -CommandType Application -ErrorAction Stop
            'Consultando aplicativos instalados pelo WinGet...' | Set-Content -LiteralPath $Saida -Encoding UTF8
            $lista = @(& $wg.Source list --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
            $codigoLista = $LASTEXITCODE
            'Consultando atualizacoes disponiveis...' | Add-Content -LiteralPath $Saida -Encoding UTF8
            $upgrades = @(& $wg.Source list --upgrade-available --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
            $codigoUpgrades = $LASTEXITCODE
            ($lista -join "`n") | Add-Content -LiteralPath $Saida -Encoding UTF8
            ($upgrades -join "`n") | Add-Content -LiteralPath $Saida -Encoding UTF8
            if ($codigoLista -ne 0) { throw ('Falha ao consultar programas (winget list): ' + $codigoLista) }
            if ($codigoUpgrades -ne 0) {
                # Em algumas versoes o WinGet retorna codigo nao zero quando nao ha atualizacoes.
                # Ainda podemos informar os programas instalados, sem afirmar que estao atualizados.
                ('Aviso: consulta de atualizacoes retornou ' + $codigoUpgrades) | Add-Content -LiteralPath $Saida -Encoding UTF8
                $upgrades = @('')
            }
            $catalogoWorker = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'catalogo.json') -Raw -Encoding UTF8)
            $linhasInstaladas = @((($lista -join "`n") -split "`r?`n") | Where-Object { $_ -and $_.Trim() })
            $linhasUpgrade = @((($upgrades -join "`n") -split "`r?`n") | Where-Object { $_ -and $_.Trim() })
            $mapa = @{}
            foreach ($appItem in $catalogoWorker) {
                # Apps do tipo Painel (como o Defender) nao possuem ID do WinGet.
                # Nunca gravar uma chave vazia no JSON: ConvertFrom-Json do Windows PowerShell 5.1 falha com nomes vazios.
                if ([string]$appItem.Tipo -in @('Painel','BuscaNomeAV')) { continue }
                $id = [string]$appItem.Id
                if ([string]::IsNullOrWhiteSpace($id)) { continue }
                # Identificador exato entre espacos de uma linha tabular, nunca busca por nome parcial.
                $padrao = '(?<![a-zA-Z0-9_.+\-])' + [regex]::Escape($id) + '(?![a-zA-Z0-9_.+\-])'
                $instalado = @($linhasInstaladas | Where-Object { $_ -match $padrao }).Count -gt 0
                $atualiza = @($linhasUpgrade | Where-Object { $_ -match $padrao }).Count -gt 0
                if ($atualiza) { $mapa[$id] = 'Atualizacao disponivel' }
                elseif ($instalado) { $mapa[$id] = 'Instalado' }
                else { $mapa[$id] = 'Nao identificado pelo WinGet' }
            }
            [pscustomobject]@{ Estado='SUCESSO'; Inventario=$mapa; Mensagem='Concluido' } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Resultado -Encoding UTF8
            exit 0
        } catch {
            $msg = $_.Exception.Message
            try { ('ERRO INVENTARIO: ' + $msg) | Add-Content -LiteralPath $Saida -Encoding UTF8 } catch {}
            try { [pscustomobject]@{ Estado='FALHA'; Mensagem=$msg } | ConvertTo-Json | Set-Content -LiteralPath $Resultado -Encoding UTF8 } catch {}
            exit 1
        }
    }
    $codigo = 1
    $erro = ''
    $estado = 'FALHA'
    $codigoOriginal = 1
    try {
        if (-not $Saida -or -not $Resultado) { throw 'Arquivos de log/resultados ausentes.' }
        if ($TipoPacote -eq 'BuscaNomeAV') {
            if ($PacoteId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9 .+_-]{1,100}$') { throw 'Nome invalido.' }
        } elseif ($PacoteId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.+-]{1,140}$') { throw 'ID de pacote invalido.' }
        $winget = Get-Command winget.exe -CommandType Application -ErrorAction Stop
        $argsWinget = @($Operacao)
        if ($TipoPacote -eq 'BuscaNomeAV') { $argsWinget += @('--name',$PacoteId) }
        else { $argsWinget += @('--id',$PacoteId) }
        $argsWinget += @('--exact','--source','winget','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
        if ($ArquiteturaPacote) {
            if ($ArquiteturaPacote -notin @('x64','x86','arm64','arm')) { throw 'Arquitetura nao suportada.' }
            $argsWinget += @('--architecture',$ArquiteturaPacote)
        }
        if ($Operacao -in @('install','upgrade')) { $argsWinget += '--silent' }
        if ($Operacao -eq 'install') { $argsWinget += '--no-upgrade' }
        if ($Operacao -eq 'download') {
            if (-not $PastaDownload) { throw 'Pasta para download ausente.' }
            [void](New-Item -Path $PastaDownload -ItemType Directory -Force)
            $argsWinget += @('--download-directory',$PastaDownload)
        }
        ('Comando: winget ' + ($argsWinget -join ' ')) | Set-Content -LiteralPath $Saida -Encoding UTF8
        $ErrorActionPreference = 'Continue'
        & $winget.Source @argsWinget *>&1 | Out-File -LiteralPath $Saida -Encoding UTF8 -Append
        if ($null -ne $LASTEXITCODE) { $codigo = [int64]$LASTEXITCODE }
        else { $codigo = 1 }
        if ($codigo -eq 0 -and $Operacao -eq 'download') {
            $arquivos = @(Get-ChildItem -Path $PastaDownload -File -Recurse -ErrorAction SilentlyContinue)
            if ($arquivos.Count -eq 0) {
                $erro = 'WinGet retornou 0, mas nao foram encontrados arquivos na pasta de download.'
                $codigo = 1
            } else { ('Arquivos encontrados na pasta: ' + $arquivos.Count) | Add-Content -LiteralPath $Saida -Encoding UTF8 }
        }
        $codigoOriginal = $codigo
        # Codigos oficiais de WinGet para aplicativo existente ou ja instalado.
        $codigosJaInstalado = @(-1978335135, -1978334963)
        if ($Operacao -eq 'install' -and $codigo -in $codigosJaInstalado) {
            $estado = 'JA_INSTALADO'; $codigo = 0
        } elseif ($codigo -eq 0) {
            $estado = 'SUCESSO'
            if ($Operacao -eq 'install' -and (Test-Path -LiteralPath $Saida)) {
                $conteudo = Get-Content -LiteralPath $Saida -Raw -ErrorAction SilentlyContinue
                if ($conteudo -match '(?i)No available upgrade found|No newer package versions are available|Nenhuma atualiza.{0,20}dispon.vel|j. est. na vers.o mais recente') {
                    $estado = 'JA_INSTALADO'
                }
            }
        }
        if ($Operacao -eq 'upgrade' -and (Test-Path -LiteralPath $Saida)) {
            $conteudoUp = Get-Content -LiteralPath $Saida -Raw -ErrorAction SilentlyContinue
            if ($conteudoUp -match '(?i)No available upgrade found|No applicable update found|Nenhuma atualiza.{0,40}dispon.vel|N.o h. atualiza.{0,40}dispon.vel') {
                $estado = 'JA_ATUALIZADO'; $codigo = 0
            }
        }
        if ($codigo -ne 0 -and -not $erro) { $erro = 'WinGet retornou codigo de falha. Confira o log do pacote.' }
    } catch {
        $erro = $_.Exception.Message
        try { ('ERRO: ' + $erro) | Add-Content -LiteralPath $Saida -Encoding UTF8 } catch { }
        $codigo = 1
    }
    try {
        [pscustomobject]@{Codigo=$codigo;CodigoOriginal=$codigoOriginal;Estado=$estado;Erro=$erro;Operacao=$Operacao;Pacote=$PacoteId} |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $Resultado -Encoding UTF8
    } catch { }
    if ($codigo -eq 0) { exit 0 } else { exit 1 }
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$catalogo = Join-Path $PSScriptRoot 'catalogo.json'
if (-not (Test-Path -LiteralPath $catalogo)) { throw 'catalogo.json ausente. Extraia o ZIP por completo.' }
# IMPORTANTE: ConvertFrom-Json do Windows PowerShell pode entregar o array JSON
# como UM objeto de pipeline. Nao envolver diretamente ConvertFrom-Json em @(...).
# A enumeracao abaixo copia cada registro para uma ArrayList individualmente.
$jsonText = Get-Content -LiteralPath $catalogo -Raw -Encoding UTF8
$dadosCatalogo = ConvertFrom-Json -InputObject $jsonText
$script:apps = New-Object System.Collections.ArrayList
foreach ($registro in $dadosCatalogo) {
    if ($null -eq $registro -or [string]::IsNullOrWhiteSpace([string]$registro.Nome) -or [string]::IsNullOrWhiteSpace([string]$registro.Grupo)) {
        throw 'Registro do catalogo invalido. Confira catalogo.json.'
    }
    $registro | Add-Member -NotePropertyName Chave -NotePropertyValue ([string]$script:apps.Count)
    [void]$script:apps.Add($registro)
}
# Falhar explicitamente, em vez de abrir a janela com 1 item agrupando o catalogo inteiro.
if ($script:apps.Count -lt 1) { throw 'Catalogo vazio.' }
# O catalogo e dinamico: novos aplicativos nao exigem modificar o script.
$chavesUnicas = @{}
foreach ($registro in $script:apps) {
    if ([string]$registro.Tipo -notin @('Normal','Antivirus','BuscaNomeAV','Scanner','Painel')) { throw ('Tipo invalido: ' + $registro.Nome) }
    $identidade = ([string]$registro.Grupo + '|' + [string]$registro.Nome).ToLowerInvariant()
    if ($chavesUnicas.ContainsKey($identidade)) { throw ('Registro duplicado: ' + $registro.Nome) }
    $chavesUnicas[$identidade] = $true
}

$script:grupos = @('Todos os programas','Navegadores','Compactadores','Seguranca','PDF e Escritorio','Utilitarios','Multimidia','Comunicacao','Desenvolvimento','Imagem e Design','Impressao 3D','Armazenamento','Componentes')
foreach ($g in @($script:apps | ForEach-Object { [string]$_.Grupo } | Select-Object -Unique)) {
    if ($g -and $g -notin $script:grupos) { $script:grupos += $g }
}
$script:gruposBonitos = @{'Seguranca'='Segurança';'PDF e Escritorio'='PDF e Escritório';'Utilitarios'='Utilitários';'Multimidia'='Multimídia';'Comunicacao'='Comunicação';'Impressao 3D'='Impressão 3D'}
$script:grupoAtivo = 'Todos os programas'
$script:marcados = @{}
$script:executando = $false
$script:atualizando = $false
$script:fila = New-Object System.Collections.Queue
$script:processo = $null
$script:atual = $null
$script:total = 0
$script:concluidos = 0
$script:sucessos = 0
$script:falhas = 0
$script:jaInstalados = 0
$script:statusPorApp = @{}
foreach ($registro in $script:apps) {
    if ($registro.Tipo -eq 'Painel') { $script:statusPorApp[[string]$registro.Chave] = 'Integrado ao Windows' }
    elseif ($registro.Tipo -eq 'BuscaNomeAV') { $script:statusPorApp[[string]$registro.Chave] = 'Verificacao manual' }
}
$script:ultimoStatusWinget = ''
$script:contador = 0
$script:operacaoAtual = 'install'
$script:tipStatus = New-Object System.Windows.Forms.ToolTip
$script:inventario = @{}
$script:inventarioRodando = $false
$script:processoInventario = $null
$script:inventarioPronto = $false
$script:inicioPacote = Get-Date
$script:session = Join-Path $env:TEMP ('CentralApps-v8.5.3-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
[void](New-Item -ItemType Directory -Path $script:session -Force)
$script:logFile = Join-Path $script:session 'Central.log'
$script:pastaDownloads = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'CentralApps'
$script:arquivoInventario = Join-Path $script:session 'inventario.json'
$script:logInventario = Join-Path $script:session 'inventario-winget.txt'
$script:azul = [System.Drawing.Color]::FromArgb(20,100,196)
$script:azulEscuro = [System.Drawing.Color]::FromArgb(16,51,92)
$script:texto = [System.Drawing.Color]::FromArgb(38,53,72)
$script:cinza = [System.Drawing.Color]::FromArgb(105,119,138)
$script:fundo = [System.Drawing.Color]::FromArgb(244,247,252)
$script:borda = [System.Drawing.Color]::FromArgb(226,231,239)

function Fonte([float]$size,[bool]$bold=$false) {
    $style = [System.Drawing.FontStyle]::Regular
    if ($bold) { $style = [System.Drawing.FontStyle]::Bold }
    return [System.Drawing.Font]::new('Segoe UI',$size,$style)
}
# Icônes locais do projeto: imagens originais das categorias. Quando o programa
# estiver instalado, tentamos mostrar seu icone real via executavel local.
$script:iconeDir = Join-Path $PSScriptRoot 'assets\icons'
$script:iconeCache = @{}
$script:iconesCategorias = @{
    'Todos os programas'='todos'; 'Navegadores'='navegadores'; 'Compactadores'='compactadores'
    'Seguranca'='seguranca'; 'PDF e Escritorio'='escritorio'; 'Utilitarios'='utilitarios'
    'Multimidia'='multimidia'; 'Comunicacao'='comunicacao'; 'Desenvolvimento'='desenvolvimento'
    'Imagem e Design'='imagem'; 'Impressao 3D'='impressao'; 'Armazenamento'='armazenamento'
    'Componentes'='componentes'
}
function ImagemLocal([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    # Copia a imagem para memoria: nao bloqueia arquivos durante futuras atualizacoes.
    try {
        $bytes = [IO.File]::ReadAllBytes($file)
        $stream = [IO.MemoryStream]::new($bytes)
        try {
            $temp = [Drawing.Image]::FromStream($stream)
            try { return [Drawing.Bitmap]::new($temp) }
            finally { $temp.Dispose() }
        } finally { $stream.Dispose() }
    } catch { return $null }
}
function ImagemCategoria([string]$grupo) {
    if (-not $script:iconesCategorias.ContainsKey($grupo)) { $grupo = 'Componentes' }
    $nome = [string]$script:iconesCategorias[$grupo]
    $chave = 'cat:' + $nome
    if (-not $script:iconeCache.ContainsKey($chave)) {
        $script:iconeCache[$chave] = ImagemLocal (Join-Path $script:iconeDir ($nome + '.png'))
    }
    return $script:iconeCache[$chave]
}
# O mapeamento abaixo e local: nao baixa imagens de terceiros e nao exige internet.
$script:executaveisConhecidos = @{
    'Google.Chrome' = @('Google\Chrome\Application\chrome.exe')
    'Brave.Brave' = @('BraveSoftware\Brave-Browser\Application\brave.exe')
    'Microsoft.Edge' = @('Microsoft\Edge\Application\msedge.exe')
    'Mozilla.Firefox' = @('Mozilla Firefox\firefox.exe')
    'Opera.Opera' = @('Opera\launcher.exe')
    '7zip.7zip' = @('7-Zip\7zFM.exe')
    'RARLab.WinRAR' = @('WinRAR\WinRAR.exe')
    'Microsoft.VisualStudioCode' = @('Microsoft VS Code\Code.exe')
    'VideoLAN.VLC' = @('VideoLAN\VLC\vlc.exe')
    'Notepad++.Notepad++' = @('Notepad++\notepad++.exe')
}
function IconeInstalado([object]$app) {
    $id = [string]$app.Id
    $paths = @()
    if ($script:executaveisConhecidos.ContainsKey($id)) {
        foreach ($relative in $script:executaveisConhecidos[$id]) {
            foreach ($basePath in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
                if (-not [string]::IsNullOrWhiteSpace($basePath)) { $paths += (Join-Path $basePath $relative) }
            }
        }
    }
    foreach ($candidate in $paths) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $icon = [Drawing.Icon]::ExtractAssociatedIcon($candidate)
            if ($null -ne $icon) {
                try { return $icon.ToBitmap() }
                finally { $icon.Dispose() }
            }
        } catch { }
    }
    return $null
}
function IconeAplicativo([object]$app) {
    $key = 'app:' + [string]$app.Chave
    if ($script:iconeCache.ContainsKey($key)) { return $script:iconeCache[$key] }
    $img = IconeInstalado $app
    if ($null -eq $img) { $img = ImagemCategoria ([string]$app.Grupo) }
    $script:iconeCache[$key] = $img
    return $img
}
function Log([string]$message) {
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $message
    if ($script:txtLog -and -not $script:txtLog.IsDisposed) {
        $script:txtLog.AppendText($line + [Environment]::NewLine)
        $script:txtLog.SelectionStart = $script:txtLog.TextLength
        $script:txtLog.ScrollToCaret()
    }
    Add-Content -LiteralPath $script:logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}
function Visiveis {
    $term = [string]$script:txtPesquisa.Text
    $term = $term.Trim()
    $group = $script:grupoAtivo
    return @($script:apps | Where-Object {
        ($group -eq 'Todos os programas' -or $_.Grupo -eq $group) -and
        (-not $script:chkSomenteSelecionados -or -not $script:chkSomenteSelecionados.Checked -or $script:marcados.ContainsKey([string]$_.Chave)) -and
        ($term.Length -eq 0 -or ([string]$_.Nome).IndexOf($term,[System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.Nota).IndexOf($term,[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
}
function EstilizarStatus([System.Windows.Forms.Label]$label,[string]$estado) {
    if ($null -eq $label) { return }
    $label.Text = $estado
    $label.BackColor = [System.Drawing.Color]::FromArgb(238,242,248)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(80,96,117)
    if ($estado -match '(?i)^Instalado$|^Ja instalado$|^Baixado$|^Atualizado$|^Painel aberto$|^Integrado ao Windows$') {
        $label.BackColor = [System.Drawing.Color]::FromArgb(220,245,232)
        $label.ForeColor = [System.Drawing.Color]::FromArgb(16,114,72)
    } elseif ($estado -match '(?i)Atualizacao disponivel') {
        $label.BackColor = [System.Drawing.Color]::FromArgb(221,234,253)
        $label.ForeColor = [System.Drawing.Color]::FromArgb(24,87,173)
    } elseif ($estado -match '(?i)Baixando|Instalando|Verificando|Iniciando|Na fila') {
        $label.BackColor = [System.Drawing.Color]::FromArgb(230,237,255)
        $label.ForeColor = [System.Drawing.Color]::FromArgb(56,83,176)
    } elseif ($estado -match '(?i)Falhou|indisponivel|FALHA') {
        $label.BackColor = [System.Drawing.Color]::FromArgb(255,234,232)
        $label.ForeColor = [System.Drawing.Color]::FromArgb(166,54,53)
    }
}
function CorCategoria([string]$grupo) {
    switch ($grupo) {
        'Navegadores' { return [System.Drawing.Color]::FromArgb(226,239,255) }
        'Compactadores' { return [System.Drawing.Color]::FromArgb(245,233,255) }
        'Seguranca' { return [System.Drawing.Color]::FromArgb(225,245,242) }
        'Desenvolvimento' { return [System.Drawing.Color]::FromArgb(235,236,253) }
        'Multimidia' { return [System.Drawing.Color]::FromArgb(255,238,224) }
        'Comunicacao' { return [System.Drawing.Color]::FromArgb(229,244,255) }
        default { return [System.Drawing.Color]::FromArgb(236,241,249) }
    }
}
function DefinirStatus([string]$chave,[string]$descricao) {
    $script:statusPorApp[$chave] = $descricao
    if ($script:listaApps -and -not $script:listaApps.IsDisposed) {
        foreach ($card in $script:listaApps.Controls) {
            foreach ($control in $card.Controls) {
                if ($control -is [System.Windows.Forms.Label] -and [string]$control.Tag -eq ('status:' + $chave)) {
                    EstilizarStatus $control $descricao
                }
            }
        }
    }
}
function Recontar {
    $number = [int]$script:marcados.Count
    $script:lblSelecionados.Text = "$number selecionado(s)"
    $abaAplicativos = ($null -eq $script:tabs -or $script:tabs.SelectedIndex -eq 0)
    $script:btnTodos.Enabled = (-not $script:executando -and $abaAplicativos)
    $script:btnLimpar.Enabled = (-not $script:executando -and $abaAplicativos)
    $script:btnBaixar.Enabled = (-not $script:executando -and $number -gt 0 -and $abaAplicativos)
    $script:btnInstalar.Enabled = (-not $script:executando -and -not $script:inventarioRodando -and $number -gt 0 -and $abaAplicativos)
    $script:btnBaixar.Enabled = (-not $script:executando -and -not $script:inventarioRodando -and $number -gt 0 -and $abaAplicativos)
    if ($script:btnAtualizar) { $script:btnAtualizar.Enabled = (-not $script:executando -and -not $script:inventarioRodando -and $number -gt 0 -and $abaAplicativos) }
    if ($script:btnInventario) { $script:btnInventario.Enabled = (-not $script:executando -and -not $script:inventarioRodando) }
}
function ReestilizarCategorias {
    # Estilo discreto: faixa azul apenas no grupo ativo, contadores suaves.
    if (-not $script:grupoPanel) { return }
    foreach ($ctrl in $script:grupoPanel.Controls) {
        if ($ctrl -isnot [System.Windows.Forms.Button]) { continue }
        $ativo = ([string]$ctrl.Tag -eq $script:grupoAtivo)
        if ($ativo) {
            $ctrl.BackColor = [System.Drawing.Color]::FromArgb(233,242,253)
            $ctrl.ForeColor = [System.Drawing.Color]::FromArgb(21,79,155)
            $ctrl.Font = Fonte 9.0 $true
        } else {
            $ctrl.BackColor = [System.Drawing.Color]::White
            $ctrl.ForeColor = [System.Drawing.Color]::FromArgb(77,91,111)
            $ctrl.Font = Fonte 9.0
        }
        foreach ($sub in $ctrl.Controls) {
            if ([string]$sub.Tag -eq 'contador') {
                if ($ativo) {
                    $sub.BackColor = [System.Drawing.Color]::FromArgb(214,229,249)
                    $sub.ForeColor = [System.Drawing.Color]::FromArgb(31,90,167)
                } else {
                    $sub.BackColor = [System.Drawing.Color]::FromArgb(243,246,250)
                    $sub.ForeColor = [System.Drawing.Color]::FromArgb(118,132,151)
                }
            } elseif ([string]$sub.Tag -eq 'faixa') {
                $sub.Visible = $ativo
            }
        }
    }
}
function AtualizarLargura {
    $w = [Math]::Max(380, [int]$script:listaApps.ClientSize.Width - 29)
    foreach ($card in $script:listaApps.Controls) {
        $card.Width = $w
        foreach ($ctrl in $card.Controls) {
            $tag = [string]$ctrl.Tag
            if ($tag -like 'status:*') { $ctrl.Left = [Math]::Max(195,$w - 209) }
            elseif ($tag -like 'nome:*') { $ctrl.Width = [Math]::Max(110,$w - 326) }
            elseif ($tag -like 'descricao:*' -or $tag -like 'aviso:*') { $ctrl.Width = [Math]::Max(220,$w - 112) }
        }
    }
}
function MostrarAplicativos {
    if (-not $script:listaApps) { return }
    $script:atualizando = $true
    try {
        $script:listaApps.SuspendLayout()
        $script:listaApps.Controls.Clear()
        $visiveis = @(Visiveis)
        $w = [Math]::Max(380, [int]$script:listaApps.ClientSize.Width - 29)
        foreach ($app in $visiveis) {
            $key = [string]$app.Chave
            $temAvisoLicenca = -not [string]::IsNullOrWhiteSpace([string]$app.AvisoLicenca)
            $card = New-Object System.Windows.Forms.Panel
            $card.Width = $w
            $card.Height = if ($temAvisoLicenca) { 76 } else { 58 }
            $card.Margin = [System.Windows.Forms.Padding]::new(3,2,3,2)
            $card.BackColor = if ($script:marcados.ContainsKey($key)) { [System.Drawing.Color]::FromArgb(234,242,254) } else { [System.Drawing.Color]::White }
            $card.Tag = 'cartao:' + $key
            # Icone real do programa, quando disponivel no Windows, ou pictograma da categoria.
            $simbolo = New-Object System.Windows.Forms.PictureBox
            $simbolo.Image = IconeAplicativo $app
            $simbolo.Location = [System.Drawing.Point]::new(42,12)
            $simbolo.Size = [System.Drawing.Size]::new(31,31)
            $simbolo.SizeMode = 'Zoom'
            $simbolo.BackColor = [System.Drawing.Color]::Transparent
            [void]$card.Controls.Add($simbolo)
            $box = New-Object System.Windows.Forms.CheckBox
            $box.Location = [System.Drawing.Point]::new(14,14)
            $box.Width = 22; $box.Height = 24
            $box.Tag = $key
            $box.Text = ''
            $box.Checked = $script:marcados.ContainsKey($key)
            $box.BackColor = [System.Drawing.Color]::Transparent
            $box.Add_CheckedChanged({
                param($sender,$eventArgs)
                if ($script:atualizando -or $script:executando) { return }
                $itemKey = [string]$sender.Tag
                if ($sender.Checked) { $script:marcados[$itemKey] = $true }
                else { [void]$script:marcados.Remove($itemKey) }
                if ($sender.Parent) {
                    $sender.Parent.BackColor = if ($sender.Checked) { [System.Drawing.Color]::FromArgb(234,242,254) } else { [System.Drawing.Color]::White }
                }
                Recontar
                if ($script:chkSomenteSelecionados -and $script:chkSomenteSelecionados.Checked -and -not $sender.Checked) {
                    MostrarAplicativos
                }
            })
            [void]$card.Controls.Add($box)
            $nome = New-Object System.Windows.Forms.Label
            $nome.Text = [string]$app.Nome
            $nome.Tag = 'nome:' + $key
            $nome.Location = [System.Drawing.Point]::new(88,7)
            $nome.Width = [Math]::Max(110,$w-326); $nome.Height = 24
            $nome.AutoEllipsis = $true
            $nome.Font = Fonte 10.2 $true
            $nome.ForeColor = $script:texto
            [void]$card.Controls.Add($nome)
            $estadoLabel = New-Object System.Windows.Forms.Label
            $estadoLabel.Tag = 'status:' + $key
            $estadoLabel.Location = [System.Drawing.Point]::new(($w-209),10)
            $estadoLabel.Size = [System.Drawing.Size]::new(193,23)
            $estadoLabel.TextAlign = 'MiddleCenter'
            $estadoLabel.AutoEllipsis = $true
            $estadoLabel.Font = Fonte 8.1 $true
            $estado = if ($script:statusPorApp.ContainsKey($key)) { [string]$script:statusPorApp[$key] } else { 'A verificar' }
            EstilizarStatus $estadoLabel $estado
            $script:tipStatus.SetToolTip($estadoLabel, 'Status do WinGet. Nao identificado nao significa necessariamente ausente no Windows.')
            [void]$card.Controls.Add($estadoLabel)
            $descricao = New-Object System.Windows.Forms.Label
            $descricao.Text = if ([string]::IsNullOrWhiteSpace([string]$app.Nota)) { 'Instalacao automatizada pelo WinGet.' } else { [string]$app.Nota }
            $descricao.Tag = 'descricao:' + $key
            $descricao.Location = [System.Drawing.Point]::new(88,32)
            $descricao.Width = [Math]::Max(220,$w-112)
            $descricao.Height = 18
            $descricao.AutoEllipsis = $true
            $descricao.ForeColor = $script:cinza
            $descricao.Font = Fonte 8.6
            [void]$card.Controls.Add($descricao)
            if ($temAvisoLicenca) {
                $aviso = New-Object System.Windows.Forms.Label
                $aviso.Text = 'LICENCA: ' + [string]$app.AvisoLicenca
                $aviso.Tag = 'aviso:' + $key
                $aviso.Location = [System.Drawing.Point]::new(88,52)
                $aviso.Width = [Math]::Max(220,$w-112)
                $aviso.Height = 18
                $aviso.AutoEllipsis = $true
                $aviso.ForeColor = [System.Drawing.Color]::FromArgb(156,83,25)
                $aviso.Font = Fonte 8.1 $true
                $script:tipStatus.SetToolTip($aviso, ($aviso.Text + "`r`n" + [string]$app.UrlLicenca))
                [void]$card.Controls.Add($aviso)
            }
            [void]$script:listaApps.Controls.Add($card)
        }
        $script:lblResultados.Text = "$($visiveis.Count) de $($script:apps.Count) programas"
        ReestilizarCategorias
    } finally {
        $script:listaApps.ResumeLayout($true)
        # Filtrar ou trocar categoria deve sempre exibir o primeiro cartao inteiro.
        # Zero e a posicao inicial em paineis com AutoScroll.
        $script:listaApps.AutoScrollPosition = [System.Drawing.Point]::new(0,0)
        $script:atualizando = $false
    }
}
function IniciarInventario {
    if ($script:inventarioRodando -or $script:executando) { return }
    if (-not (Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        Log 'Inventario nao iniciado: WinGet indisponivel.'
        return
    }
    try {
        $script:inventarioRodando = $true
        $script:lblResultados.Text = 'Consultando inventario...' 
        $script:lblAtividade.Text = 'Consultando aplicativos instalados...'
        Recontar
        $origem = Join-Path $PSScriptRoot 'Central-de-Aplicativos.ps1'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $PSHOME 'powershell.exe'
        $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -File "' + $origem + '" -Worker -Operacao inventory -Saida "' + $script:logInventario + '" -Resultado "' + $script:arquivoInventario + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $script:processoInventario = New-Object System.Diagnostics.Process
        $script:processoInventario.StartInfo = $psi
        if (-not $script:processoInventario.Start()) { throw 'Nao foi possivel iniciar consulta.' }
        Log 'Verificacao de aplicativos iniciada em segundo plano.'
    } catch {
        $script:inventarioRodando = $false
        if ($script:processoInventario) { $script:processoInventario.Dispose(); $script:processoInventario = $null }
        Log ('Falha ao iniciar inventario: ' + $_.Exception.Message)
        Recontar
    }
}
function FinalizarInventario {
    if (-not $script:inventarioRodando -or -not $script:processoInventario) { return }
    if (-not $script:processoInventario.HasExited) { return }
    $exitInventario = $script:processoInventario.ExitCode
    $script:processoInventario.Dispose(); $script:processoInventario=$null
    $script:inventarioRodando = $false
    if ($exitInventario -eq 0 -and (Test-Path -LiteralPath $script:arquivoInventario)) {
        try {
            $resultadoInv = Get-Content -LiteralPath $script:arquivoInventario -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$resultadoInv.Estado -ne 'SUCESSO') { throw [string]$resultadoInv.Mensagem }
            $script:inventario = @{}
            foreach ($prop in $resultadoInv.Inventario.PSObject.Properties) {
                $nomePropriedade = [string]$prop.Name
                if ([string]::IsNullOrWhiteSpace($nomePropriedade)) { continue }
                $script:inventario[$nomePropriedade] = [string]$prop.Value
            }
            foreach ($app in $script:apps) {
                $id = [string]$app.Id
                if ($app.Tipo -eq 'Painel') { DefinirStatus ([string]$app.Chave) 'Integrado ao Windows' }
                elseif ($app.Tipo -eq 'BuscaNomeAV') { DefinirStatus ([string]$app.Chave) 'Verificacao manual' }
                elseif ($script:inventario.ContainsKey($id)) { DefinirStatus ([string]$app.Chave) ([string]$script:inventario[$id]) }
            }
            $script:inventarioPronto=$true
            $instalados=@($script:inventario.Values | Where-Object { $_ -eq 'Instalado' }).Count
            $updates=@($script:inventario.Values | Where-Object { $_ -eq 'Atualizacao disponivel' }).Count
            Log ('Inventario: ' + $instalados + ' instalados; ' + $updates + ' atualizacoes disponiveis (detectados pelo WinGet).')
            $script:lblAtividade.Text = 'Verificacao concluida. Resultados identificados pelo WinGet.'
        } catch {
            Log ('Falha ao processar inventario: ' + $_.Exception.Message)
            Log ('Detalhes: ' + $_.ScriptStackTrace)
            $script:lblAtividade.Text = 'Falha no inventario. Consulte o log; os aplicativos nao foram verificados.'
            $script:lblResultados.Text = "$($script:apps.Count) programas (verificacao indisponivel)"
            foreach ($app in $script:apps) {
                if ($app.Tipo -eq 'Painel') { DefinirStatus ([string]$app.Chave) 'Integrado ao Windows' }
                elseif ($app.Tipo -eq 'BuscaNomeAV') { DefinirStatus ([string]$app.Chave) 'Verificacao manual' }
                else { DefinirStatus ([string]$app.Chave) 'Verificacao indisponivel' }
            }
        }
    } else {
        Log ('Inventario nao concluido. Consulte ' + $script:logInventario)
        $script:lblAtividade.Text = 'Nao foi possivel verificar aplicativos. Veja o log.'
        $script:lblResultados.Text = "$($script:apps.Count) programas (verificacao indisponivel)"
    }
    # Atualiza a contagem mesmo que o usuario tenha mudado de categoria durante a consulta.
    $quantosVisiveis = @(Visiveis).Count
    $script:lblResultados.Text = "$quantosVisiveis de $($script:apps.Count) programas"
    Recontar
}
function Bloquear([bool]$state) {
    $script:executando = $state
    $script:btnTodos.Enabled = -not $state
    $script:btnLimpar.Enabled = -not $state
    $script:txtPesquisa.Enabled = -not $state
    if ($script:chkSomenteSelecionados) { $script:chkSomenteSelecionados.Enabled = -not $state }
    foreach ($btn in $script:grupoPanel.Controls) { $btn.Enabled = -not $state }
    foreach ($card in $script:listaApps.Controls) { foreach ($c in $card.Controls) { if ($c -is [System.Windows.Forms.CheckBox]) { $c.Enabled = -not $state } } }
    Recontar
}
function Progresso {
    if ($script:total -gt 0) { $script:barra.Value = [int][Math]::Min(100,100.0*$script:concluidos/$script:total) }
}
function FimDaFila {
    Bloquear $false
    $script:barraAtividade.Style = 'Blocks'
    $script:barraAtividade.Value = 0
    $script:barraAtividade.Visible = $false
    $script:barra.Visible = $false
    $script:lblAtividade.Text = 'Operacao finalizada. Se desejar, abra os detalhes do processo.'
    $script:lblEstado.Text = "Concluido: $($script:sucessos) sucesso(s), $($script:jaInstalados) ja instalado(s)/sem nova versao, $($script:falhas) falha(s)."
    $script:lblEstado.ForeColor = if ($script:falhas -gt 0) { [System.Drawing.Color]::FromArgb(165,78,34) } else { [System.Drawing.Color]::FromArgb(19,125,73) }
    Log "Concluido: $($script:sucessos) sucesso(s), $($script:jaInstalados) ja instalado(s), $($script:falhas) falha(s)."
    Log ('Detalhes da operacao: ' + $script:session)
    if ($script:falhas -gt 0) { DefinirDetalhes $true }
}
function ProximoPacote {
    if ($script:fila.Count -eq 0) { FimDaFila; return }
    $script:atual = $script:fila.Dequeue()
    $app = $script:atual
    # Instalar nao deve reinstalar nem atualizar silenciosamente aplicativos reconhecidos.
    $idAtual = [string]$app.Id
    if ($script:operacaoAtual -eq 'install' -and $script:inventarioPronto -and $script:inventario.ContainsKey($idAtual) -and
        $script:inventario[$idAtual] -in @('Instalado','Atualizacao disponivel')) {
        DefinirStatus ([string]$app.Chave) ([string]$script:inventario[$idAtual])
        Log ('Ignorado (ja instalado): ' + [string]$app.Nome + '. Para atualizacoes use ATUALIZAR.')
        $script:jaInstalados++
        $script:concluidos++
        Progresso
        ProximoPacote
        return
    }
    DefinirStatus ([string]$app.Chave) 'Iniciando...'
    $script:inicioPacote = Get-Date
    $script:lblAtividade.Text = ('Etapa: iniciando ' + [string]$app.Nome)
    $script:barraAtividade.Style = 'Marquee'
    $script:barraAtividade.MarqueeAnimationSpeed = 25
    $script:ultimoStatusWinget = ''
    $script:lblEstado.Text = "$($script:operacaoAtual): $($app.Nome) ($($script:concluidos+1)/$($script:total))"
    if ($app.Tipo -eq 'Painel') {
        try {
            if ($script:operacaoAtual -eq 'download') { throw 'Defender nao possui instalador nesta central.' }
            Start-Process 'windowsdefender:' -ErrorAction Stop
            Log 'Painel do Microsoft Defender aberto (nao e instalacao).'
            $script:sucessos++
            DefinirStatus ([string]$app.Chave) 'Painel aberto'
        } catch { Log ('Falha ao abrir Defender: ' + $_.Exception.Message); $script:falhas++; DefinirStatus ([string]$app.Chave) 'Falhou' }
        $script:concluidos++; Progresso; ProximoPacote; return
    }
    $script:contador++
    $serial = '{0:D3}' -f $script:contador
    $script:logPacote = Join-Path $script:session ($serial + '-winget.txt')
    $script:resultadoPacote = Join-Path $script:session ($serial + '-resultado.json')
    $runName = Split-Path -Path $script:session -Leaf
    $downloadDest = Join-Path (Join-Path $script:pastaDownloads $runName) $serial
    $origem = Join-Path $PSScriptRoot 'Central-de-Aplicativos.ps1'
    $argString = '-NoLogo -NoProfile -NonInteractive -File "' + $origem + '" -Worker' +
        ' -Operacao ' + $script:operacaoAtual +
        ' -PacoteId "' + $app.Id + '" -TipoPacote "' + $app.Tipo + '"' +
        ' -ArquiteturaPacote "' + $app.Arquitetura + '"' +
        ' -Saida "' + $script:logPacote + '" -Resultado "' + $script:resultadoPacote + '"' +
        ' -PastaDownload "' + $downloadDest + '"'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $PSHOME 'powershell.exe'
        $psi.Arguments = $argString
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $script:processo = New-Object System.Diagnostics.Process
        $script:processo.StartInfo = $psi
        Log ("Iniciando $($script:operacaoAtual): $($app.Nome) [$($app.Id)]")
        if (-not $script:processo.Start()) { throw 'Falha ao abrir processo do WinGet.' }
    } catch {
        Log ('Erro inicializando pacote: ' + $_.Exception.Message)
        if ($script:processo) { $script:processo.Dispose() }
        $script:processo = $null
        $script:falhas++; DefinirStatus ([string]$app.Chave) 'Falhou'; $script:concluidos++; Progresso; ProximoPacote
    }
}
function Executar([string]$operacao) {
    if ($script:executando) { return }
    try {
        $lista = @($script:apps | Where-Object { $script:marcados.ContainsKey([string]$_.Chave) })
        if ($lista.Count -eq 0) { return }
        if ($operacao -in @('download','upgrade') -and @($lista | Where-Object {$_.Tipo -eq 'Painel'}).Count -gt 0) {
            [void][System.Windows.Forms.MessageBox]::Show('O Microsoft Defender ja faz parte do Windows. Retire-o da selecao para baixar instaladores.','Aviso','OK','Warning'); return
        }
        if (@($lista | Where-Object {$_.Nome -match 'Python 3' }).Count -gt 1) {
            [void][System.Windows.Forms.MessageBox]::Show('Escolha somente uma variante do Python 3 para este teste.','Variantes','OK','Warning'); return
        }
        if ($operacao -eq 'install' -and @($lista | Where-Object {$_.Tipo -in @('Antivirus','BuscaNomeAV')}).Count -gt 1) {
            [void][System.Windows.Forms.MessageBox]::Show('Selecione apenas um antivirus com protecao residente.','Seguranca','OK','Warning'); return
        }
        if (@($lista | Where-Object {$_.Tipo -ne 'Painel'}).Count -gt 0 -and -not (Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue)) {
            [void][System.Windows.Forms.MessageBox]::Show('O WinGet nao foi encontrado. Rode Testar-WinGet.cmd.','WinGet','OK','Error'); return
        }
        if (@($lista | Where-Object {$_.Tipo -eq 'BuscaNomeAV'}).Count -gt 0) {
            if ([System.Windows.Forms.MessageBox]::Show('Avast e AVG Free podem nao estar no WinGet e nao sao licenciados para uso empresarial. Continuar?','Licenciamento','YesNo','Warning') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        if (@($lista | Where-Object {$_.Nome -match 'AnyDesk|TeamViewer|UltraVNC'}).Count -gt 0) {
            if ([System.Windows.Forms.MessageBox]::Show('Acesso remoto deve ser autorizado e protegido pelo TI. Continuar?','Acesso remoto','YesNo','Warning') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        # Exibir avisos especificos para produtos com termos relevantes.
        $comAviso = @($lista | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.AvisoLicenca) })
        if ($comAviso.Count -gt 0) {
            $linhasLicenca = @($comAviso | ForEach-Object {
                $linha = '- ' + [string]$_.Nome + ': ' + [string]$_.AvisoLicenca
                if (-not [string]::IsNullOrWhiteSpace([string]$_.UrlLicenca)) { $linha += "`r`n  Termos: " + [string]$_.UrlLicenca }
                $linha
            })
            $textoLicenca = "ATENCAO A LICENCAS DE TERCEIROS:`r`n`r`n" + ($linhasLicenca -join "`r`n`r`n")
            $textoLicenca += "`r`n`r`nA Central nao fornece licencas nem armazena instaladores. Confira os termos dos desenvolvedores antes de continuar."
            if ([System.Windows.Forms.MessageBox]::Show($textoLicenca,'Licenciamento de terceiros','YesNo','Warning') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $desc = if ($operacao -eq 'download') { 'BAIXAR APENAS' } elseif ($operacao -eq 'upgrade') { 'ATUALIZAR SELECIONADOS' } else { 'BAIXAR E INSTALAR' }
        $msg = "$desc $($lista.Count) programa(s)?`r`n`r`nFonte: WinGet (winget).`r`nOs aplicativos pertencem aos seus fabricantes e o uso depende de suas licencas.`r`nO WinGet pode aceitar acordos de pacote automaticamente durante a operacao.`r`nAlguns pacotes exigem permissao administrativa ou nao oferecem modo silencioso.`r`n`r`nContinuar?"
        if ([System.Windows.Forms.MessageBox]::Show($msg,'Confirmacao','YesNo','Question') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $script:operacaoAtual = $operacao
        $script:fila.Clear()
        foreach ($a in $lista) { $script:fila.Enqueue($a) }
        $script:total = $lista.Count
        $script:concluidos = 0; $script:sucessos=0; $script:jaInstalados=0; $script:falhas=0; $script:contador=0
        foreach ($a in $lista) { DefinirStatus ([string]$a.Chave) 'Na fila' }
        $script:barra.Value = 0
        $script:barra.Visible = $true
        $script:barraAtividade.Visible = $true
        $script:lblEstado.ForeColor = $script:azulEscuro
        Bloquear $true
        Log ("Inicio da operacao: $operacao; total: $($script:total); logs: $($script:session)")
        ProximoPacote
    } catch {
        Bloquear $false
        Log ('Erro ao preparar operacao: ' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Erro','OK','Error')
    }
}

# --- Interface: botoes de categoria, sem ListBox/SelectedIndex/SetSelected ---
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Central de Aplicativos - TI | v8.6.5.6 | Desenvolvido por Julioo'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = [System.Drawing.Size]::new(1190,780)
$form.MinimumSize = [System.Drawing.Size]::new(980,640)
$form.BackColor = $script:fundo
$form.Font = Fonte 9.5
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$outer = New-Object System.Windows.Forms.TableLayoutPanel
$outer.Dock = 'Fill'
$outer.ColumnCount = 1; $outer.RowCount = 3
[void]$outer.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,88))
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,165))
[void]$form.Controls.Add($outer)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Fill'
$header.BackColor = $script:azulEscuro
$header.Margin = [System.Windows.Forms.Padding]::new(0)
$header.Add_Paint({
    param($sender,$e)
    $area = $sender.ClientRectangle
    if ($area.Width -lt 1 -or $area.Height -lt 1) { return }
    $brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new($area, [System.Drawing.Color]::FromArgb(15,43,78), [System.Drawing.Color]::FromArgb(25,91,150), [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
    try { $e.Graphics.FillRectangle($brush, $area) } finally { $brush.Dispose() }
    $line = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(57,162,226))
    try { $e.Graphics.FillRectangle($line, 0, $area.Height-3, $area.Width, 3) }
    finally { $line.Dispose() }
})
$logo = New-Object System.Windows.Forms.PictureBox
$logo.Image = ImagemLocal (Join-Path $script:iconeDir 'cabecalho.png')
$logo.Location = [System.Drawing.Point]::new(29,20)
$logo.Size = [System.Drawing.Size]::new(47,47)
$logo.SizeMode = 'Zoom'
$logo.BackColor = [System.Drawing.Color]::Transparent
[void]$header.Controls.Add($logo)
$linhaLogo = New-Object System.Windows.Forms.Panel
$linhaLogo.Location = [System.Drawing.Point]::new(82,21)
$linhaLogo.Size = [System.Drawing.Size]::new(2,44)
$linhaLogo.BackColor = [System.Drawing.Color]::FromArgb(78,158,215)
[void]$header.Controls.Add($linhaLogo)
$h1 = New-Object System.Windows.Forms.Label
$h1.Text = 'CENTRAL DE APLICATIVOS - TI'
$h1.Font = Fonte 16.5 $true
$h1.ForeColor = [System.Drawing.Color]::White
$h1.Location = [System.Drawing.Point]::new(99,15)
$h1.AutoSize = $true
$h1.BackColor = [System.Drawing.Color]::Transparent
[void]$header.Controls.Add($h1)
$h2 = New-Object System.Windows.Forms.Label
$h2.Text = 'Instalacao via WinGet  |  Aplicativos sujeitos as licencas dos fabricantes.'
$h2.ForeColor = [System.Drawing.Color]::FromArgb(216,234,249)
$h2.Font = Fonte 9.2
$h2.Location = [System.Drawing.Point]::new(101,52)
$h2.AutoSize = $true
$h2.BackColor = [System.Drawing.Color]::Transparent
[void]$header.Controls.Add($h2)
$outer.Controls.Add($header,0,0)

$center = New-Object System.Windows.Forms.TableLayoutPanel
$center.Dock = 'Fill'; $center.ColumnCount = 2; $center.RowCount = 1
$center.Margin = [System.Windows.Forms.Padding]::new(12,12,12,7)
[void]$center.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,202))
[void]$center.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
# Abas principais: a navegacao de aplicativos continua igual;
# os avisos ficam em uma aba propria, sem interferir no catalogo.
$script:tabs = New-Object System.Windows.Forms.TabControl
$script:tabs.Dock = 'Fill'
$script:tabs.Font = Fonte 10 $true
$script:tabs.Margin = [System.Windows.Forms.Padding]::new(9,5,9,4)
$script:tabs.Padding = [System.Drawing.Point]::new(18,7)
$tabAplicativos = New-Object System.Windows.Forms.TabPage
$tabAplicativos.Text = 'Aplicativos'
$tabAplicativos.BackColor = $script:fundo
$tabAplicativos.Padding = [System.Windows.Forms.Padding]::new(0)
$tabAvisos = New-Object System.Windows.Forms.TabPage
$tabAvisos.Text = 'Avisos e Licenças'
$tabAvisos.BackColor = [System.Drawing.Color]::White
$tabAvisos.Padding = [System.Windows.Forms.Padding]::new(0)
[void]$script:tabs.TabPages.Add($tabAplicativos)
[void]$script:tabs.TabPages.Add($tabAvisos)
[void]$outer.Controls.Add($script:tabs,0,1)
$center.Margin = [System.Windows.Forms.Padding]::new(8,10,8,6)
$tabAplicativos.Controls.Add($center)

# Conteudo informativo, separado da selecao de aplicativos.
$avisoLayout = New-Object System.Windows.Forms.TableLayoutPanel
$avisoLayout.Dock = 'Fill'
$avisoLayout.Padding = [System.Windows.Forms.Padding]::new(25,16,25,15)
$avisoLayout.BackColor = [System.Drawing.Color]::White
$avisoLayout.ColumnCount = 1
$avisoLayout.RowCount = 3
[void]$avisoLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,42))
[void]$avisoLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,49))
[void]$avisoLayout.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
$tabAvisos.Controls.Add($avisoLayout)
$avisoTitulo = New-Object System.Windows.Forms.Label
$avisoTitulo.Text = 'Avisos e Licenças de Terceiros'
$avisoTitulo.Dock = 'Fill'
$avisoTitulo.Font = Fonte 15 $true
$avisoTitulo.ForeColor = $script:azulEscuro
$avisoLayout.Controls.Add($avisoTitulo,0,0)
$avisoResumo = New-Object System.Windows.Forms.Label
$avisoResumo.Text = 'A Central facilita instalações; os direitos de uso de cada programa continuam definidos pelo fabricante.'
$avisoResumo.Dock = 'Fill'
$avisoResumo.Font = Fonte 10
$avisoResumo.ForeColor = $script:cinza
$avisoResumo.AutoEllipsis = $true
$avisoLayout.Controls.Add($avisoResumo,0,1)
$avisoTexto = New-Object System.Windows.Forms.RichTextBox
$avisoTexto.Dock = 'Fill'
$avisoTexto.ReadOnly = $true
$avisoTexto.BorderStyle = 'None'
$avisoTexto.TabStop = $false
$avisoTexto.DetectUrls = $false
$avisoTexto.ScrollBars = 'Vertical'
$avisoTexto.BackColor = [System.Drawing.Color]::White
$avisoTexto.ForeColor = $script:texto
$avisoTexto.Font = Fonte 10
$avisoTexto.Text = @'
O QUE A CENTRAL FAZ
A Central de Aplicativos é uma ferramenta independente que reúne programas e facilita downloads e instalações por meio do WinGet. O projeto não hospeda instaladores de terceiros, não modifica os programas e não fornece chaves ou ativações. Os downloads são obtidos das fontes cadastradas no WinGet.

LICENÇAS E PROGRAMAS PAGOS
Os aplicativos pertencem aos respectivos desenvolvedores. Instalar um programa não fornece licença nem concede direito automático de uso. Se houver versão paga, avaliação ou ativação, cabe ao usuário ou à organização adquirir a licença apropriada. Sem licença, o programa pode limitar recursos, expirar ou impedir o uso.

PROGRAMAS GRATUITOS
Gratuito para uso pessoal não significa necessariamente gratuito para uso empresarial. Confira os termos do fabricante antes de instalar ou utilizar o programa em um computador corporativo.

DOWNLOAD E TERMOS
A Central utiliza informações dos manifestos do WinGet. As fontes, os endereços e as versões podem mudar. Verifique a origem e as condições do fabricante. O WinGet pode aceitar acordos do pacote durante operações automatizadas; a confirmação na Central não substitui a leitura desses termos.

INDEPENDÊNCIA
A Central não representa, não é patrocinada e não possui vínculo oficial com os fabricantes. Nomes e marcas pertencem aos respectivos titulares.

RESPONSABILIDADE E SEGURANÇA
Antes de instalar, confirme se o programa é adequado ao computador, se a origem é confiável e se o uso é permitido. A Central não garante disponibilidade, segurança, funcionamento ou licenciamento de aplicativos de terceiros. Não são oferecidos meios para contornar licenças ou proteções.

Na dúvida, consulte os termos oficiais do fabricante antes de continuar.
'@
$avisoLayout.Controls.Add($avisoTexto,0,2)
foreach ($tituloAviso in @('O QUE A CENTRAL FAZ','LICENÇAS E PROGRAMAS PAGOS','PROGRAMAS GRATUITOS','DOWNLOAD E TERMOS','INDEPENDÊNCIA','RESPONSABILIDADE E SEGURANÇA')) {
    $inicio = $avisoTexto.Text.IndexOf($tituloAviso,[System.StringComparison]::Ordinal)
    if ($inicio -ge 0) {
        $avisoTexto.Select($inicio,$tituloAviso.Length)
        $avisoTexto.SelectionFont = Fonte 10.5 $true
        $avisoTexto.SelectionColor = $script:azul
    }
}
$avisoTexto.Select(0,0)
$script:tabs.Add_SelectedIndexChanged({ Recontar })

$side = New-Object System.Windows.Forms.Panel
$side.Dock = 'Fill'
$side.BackColor = [System.Drawing.Color]::White
$side.Margin = [System.Windows.Forms.Padding]::new(0,0,6,0)
$sideTitle = New-Object System.Windows.Forms.Label
$sideTitle.Text = 'CATEGORIAS'
$sideTitle.Font = Fonte 9.1 $true
$sideTitle.ForeColor = [System.Drawing.Color]::FromArgb(112,126,147)
$sideTitle.Location = [System.Drawing.Point]::new(14,13)
$sideTitle.AutoSize = $true
[void]$side.Controls.Add($sideTitle)
$sideDivider = New-Object System.Windows.Forms.Panel
$sideDivider.Location = [System.Drawing.Point]::new(13,36)
$sideDivider.Size = [System.Drawing.Size]::new(172,1)
$sideDivider.BackColor = [System.Drawing.Color]::FromArgb(235,239,245)
$sideDivider.Anchor = 'Top,Left,Right'
[void]$side.Controls.Add($sideDivider)

$script:grupoPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$script:grupoPanel.Location = [System.Drawing.Point]::new(4,45)
$script:grupoPanel.Size = [System.Drawing.Size]::new(190,500)
$script:grupoPanel.Anchor = 'Top,Bottom,Left,Right'
$script:grupoPanel.AutoScroll = $true
$script:grupoPanel.WrapContents = $false
$script:grupoPanel.FlowDirection = 'TopDown'
$script:grupoPanel.BackColor = [System.Drawing.Color]::White
$script:grupoPanel.Margin = [System.Windows.Forms.Padding]::new(0)
[void]$side.Controls.Add($script:grupoPanel)

# Reduz os pictogramas de 48px para 17px: evita distorcer e alargar a navegacao.
$script:navIcones = @{}
foreach ($g in $script:grupos) {
    $nome = if ($script:gruposBonitos.ContainsKey($g)) { [string]$script:gruposBonitos[$g] } else { [string]$g }
    $num = if ($g -eq 'Todos os programas') { $script:apps.Count } else { @($script:apps | Where-Object { $_.Grupo -eq $g }).Count }
    $b = New-Object System.Windows.Forms.Button
    $b.Tag = $g
    $b.Text = ' ' + $nome
    $origemImagem = ImagemCategoria $g
    if ($null -ne $origemImagem) {
        try {
            $script:navIcones[$g] = [System.Drawing.Bitmap]::new($origemImagem, [System.Drawing.Size]::new(17,17))
            $b.Image = $script:navIcones[$g]
        } catch { }
    }
    $b.ImageAlign = 'MiddleLeft'
    $b.TextImageRelation = 'ImageBeforeText'
    $b.TextAlign = 'MiddleLeft'
    $b.AutoEllipsis = $true
    $b.Width = 181
    $b.Height = 34
    $b.Font = Fonte 9.0
    $b.Padding = [System.Windows.Forms.Padding]::new(7,0,28,0)
    $b.Margin = [System.Windows.Forms.Padding]::new(2,2,0,2)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = [System.Drawing.Color]::White
    $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(242,247,253)
    $b.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(229,239,252)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.AccessibleName = ('Categoria ' + $nome + ', ' + $num + ' aplicativos')
    $script:tipStatus.SetToolTip($b, ($nome + ': ' + $num + ' programa(s)'))

    # Numero separado, alinhado a direita (sem quebrar o nome da categoria).
    $contadorLabel = New-Object System.Windows.Forms.Label
    $contadorLabel.Tag = 'contador'
    $contadorLabel.Text = [string]$num
    $contadorLabel.Location = [System.Drawing.Point]::new(149,8)
    $contadorLabel.Size = [System.Drawing.Size]::new(26,19)
    $contadorLabel.TextAlign = 'MiddleCenter'
    $contadorLabel.Font = Fonte 8.0 $true
    $contadorLabel.BackColor = [System.Drawing.Color]::FromArgb(243,246,250)
    $contadorLabel.ForeColor = [System.Drawing.Color]::FromArgb(118,132,151)
    $contadorLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $contadorLabel.AccessibleName = ('Quantidade: ' + $num)
    [void]$b.Controls.Add($contadorLabel)

    # Pequena faixa vertical em vez de bloco colorido.
    $faixa = New-Object System.Windows.Forms.Panel
    $faixa.Tag = 'faixa'
    $faixa.Location = [System.Drawing.Point]::new(0,5)
    $faixa.Size = [System.Drawing.Size]::new(3,23)
    $faixa.BackColor = [System.Drawing.Color]::FromArgb(38,114,202)
    $faixa.Visible = $false
    [void]$b.Controls.Add($faixa)

    $b.Add_Click({
        param($sender,$eventArgs)
        if ($script:executando) { return }
        $script:grupoAtivo = [string]$sender.Tag
        MostrarAplicativos
    })
    # Mesmo clicando no contador, a categoria sera selecionada.
    $contadorLabel.Add_Click({
        param($sender,$eventArgs)
        if ($script:executando) { return }
        $script:grupoAtivo = [string]$sender.Parent.Tag
        MostrarAplicativos
    })
    [void]$script:grupoPanel.Controls.Add($b)
}
$center.Controls.Add($side,0,0)

$main = New-Object System.Windows.Forms.TableLayoutPanel
$main.Dock = 'Fill'; $main.RowCount=2; $main.ColumnCount=1
$main.BackColor = [System.Drawing.Color]::White
[void]$main.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,78))
[void]$main.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
$center.Controls.Add($main,1,0)
$searchArea = New-Object System.Windows.Forms.TableLayoutPanel
$searchArea.Dock='Fill'; $searchArea.ColumnCount=3; $searchArea.RowCount=2
$searchArea.Padding = [System.Windows.Forms.Padding]::new(16,9,16,8)
[void]$searchArea.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$searchArea.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,165))
[void]$searchArea.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,155))
[void]$searchArea.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,25))
[void]$searchArea.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
$lblPesquisa = New-Object System.Windows.Forms.Label
$lblPesquisa.Text='PESQUISAR'; $lblPesquisa.ForeColor=$script:cinza
$lblPesquisa.Font=Fonte 8.6 $true; $lblPesquisa.Dock='Fill'
$searchArea.Controls.Add($lblPesquisa,0,0)
$script:chkSomenteSelecionados = New-Object System.Windows.Forms.CheckBox
$script:chkSomenteSelecionados.Text = 'Somente selecionados'
$script:chkSomenteSelecionados.Dock = 'Fill'
$script:chkSomenteSelecionados.Margin = [System.Windows.Forms.Padding]::new(4,0,0,0)
$script:chkSomenteSelecionados.Font = Fonte 8.7
$script:chkSomenteSelecionados.ForeColor = $script:cinza
$script:chkSomenteSelecionados.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:chkSomenteSelecionados.Add_CheckedChanged({ if (-not $script:executando) { MostrarAplicativos } })
$searchArea.Controls.Add($script:chkSomenteSelecionados,1,0)
$script:lblResultados=New-Object System.Windows.Forms.Label
$script:lblResultados.Dock='Fill'; $script:lblResultados.TextAlign='MiddleRight'
$script:lblResultados.ForeColor=$script:cinza; $script:lblResultados.Font=Fonte 8.6
$searchArea.Controls.Add($script:lblResultados,2,0)
$script:txtPesquisa = New-Object System.Windows.Forms.TextBox
$script:txtPesquisa.Dock='Fill'; $script:txtPesquisa.Font=Fonte 11
$script:txtPesquisa.BorderStyle = 'FixedSingle'
$script:txtPesquisa.BackColor = [System.Drawing.Color]::FromArgb(250,252,255)
$searchArea.Controls.Add($script:txtPesquisa,0,1)
$searchArea.SetColumnSpan($script:txtPesquisa,2)
$script:btnInventario = New-Object System.Windows.Forms.Button
$script:btnInventario.Text = '↻  Verificar instalados'
$script:btnInventario.Dock='Fill'
$script:btnInventario.Font=Fonte 8.7 $true
$script:btnInventario.FlatStyle='Flat'
$script:btnInventario.BackColor=[System.Drawing.Color]::FromArgb(237,242,249)
$script:btnInventario.ForeColor=$script:azulEscuro
$script:btnInventario.Margin=[System.Windows.Forms.Padding]::new(5,1,2,0)
$script:btnInventario.Add_Click({ IniciarInventario })
$searchArea.Controls.Add($script:btnInventario,2,1)
$main.Controls.Add($searchArea,0,0)
$script:listaApps=New-Object System.Windows.Forms.FlowLayoutPanel
$script:listaApps.Dock='Fill'; $script:listaApps.AutoScroll=$true
$script:listaApps.WrapContents=$false
$script:listaApps.FlowDirection='TopDown'
$script:listaApps.BackColor=$script:fundo
$script:listaApps.Padding=[System.Windows.Forms.Padding]::new(8,5,8,5)
$main.Controls.Add($script:listaApps,0,1)
$script:txtPesquisa.Add_TextChanged({ if (-not $script:executando) { MostrarAplicativos } })
$script:listaApps.Add_SizeChanged({ if (-not $script:atualizando) { AtualizarLargura } })

$bottom = New-Object System.Windows.Forms.TableLayoutPanel
$bottom.Dock='Fill'; $bottom.Margin=[System.Windows.Forms.Padding]::new(0)
$bottom.BackColor=[System.Drawing.Color]::White
$bottom.Padding=[System.Windows.Forms.Padding]::new(16,6,16,8)
$bottom.ColumnCount=1; $bottom.RowCount=7
[void]$bottom.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,42))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,23))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,21))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,23))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,19))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,22))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
$outer.Controls.Add($bottom,0,2)
$actions = New-Object System.Windows.Forms.TableLayoutPanel
$actions.Dock='Fill'; $actions.RowCount=1; $actions.ColumnCount=6
[void]$actions.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$actions.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,120))
[void]$actions.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,116))
[void]$actions.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,142))
[void]$actions.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,172))
[void]$actions.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,205))
$bottom.Controls.Add($actions,0,0)
$script:lblSelecionados = New-Object System.Windows.Forms.Label
$script:lblSelecionados.Dock='Fill'; $script:lblSelecionados.TextAlign='MiddleLeft'
$script:lblSelecionados.Font=Fonte 10.5 $true; $script:lblSelecionados.ForeColor=$script:texto
$actions.Controls.Add($script:lblSelecionados,0,0)
function Botao([string]$titulo,[bool]$primario) {
    $b=New-Object System.Windows.Forms.Button
    $b.Dock='Fill'; $b.Text=$titulo; $b.FlatStyle='Flat'; $b.Margin=[System.Windows.Forms.Padding]::new(3,7,3,6)
    if ($primario) { $b.BackColor=$script:azul; $b.ForeColor=[System.Drawing.Color]::White; $b.FlatAppearance.BorderSize=0; $b.Font=Fonte 9.5 $true }
    else { $b.BackColor=[System.Drawing.Color]::FromArgb(237,242,249); $b.ForeColor=$script:texto; $b.FlatAppearance.BorderColor=$script:borda; $b.Font=Fonte 9 }
    return $b
}
$script:btnTodos = Botao 'Marcar visiveis' $false
$actions.Controls.Add($script:btnTodos,1,0)
$script:btnLimpar = Botao 'Limpar selecao' $false
$actions.Controls.Add($script:btnLimpar,2,0)
$script:btnBaixar = Botao 'BAIXAR APENAS' $false
$actions.Controls.Add($script:btnBaixar,3,0)
$script:btnAtualizar = Botao 'ATUALIZAR SELECIONADOS' $false
$actions.Controls.Add($script:btnAtualizar,4,0)
$script:btnInstalar = Botao 'BAIXAR E INSTALAR' $true
$actions.Controls.Add($script:btnInstalar,5,0)
$script:lblEstado = New-Object System.Windows.Forms.Label
$script:lblEstado.Dock='Fill'; $script:lblEstado.TextAlign='MiddleLeft'
$script:lblEstado.Text='Pronto. Selecione um programa para iniciar.'
$script:lblEstado.ForeColor=$script:cinza
$bottom.Controls.Add($script:lblEstado,0,1)
$script:barra = New-Object System.Windows.Forms.ProgressBar
$script:barra.Dock='Fill'; $script:barra.Maximum=100; $script:barra.Style='Continuous'
$script:barra.Margin = [System.Windows.Forms.Padding]::new(1,5,1,6)
$bottom.Controls.Add($script:barra,0,2)
$script:lblAtividade = New-Object System.Windows.Forms.Label
$script:lblAtividade.Dock = 'Fill'
$script:lblAtividade.Text = 'Sem operacao ativa.'
$script:lblAtividade.ForeColor = $script:cinza
$script:lblAtividade.TextAlign = 'MiddleLeft'
$bottom.Controls.Add($script:lblAtividade,0,3)
$script:barraAtividade = New-Object System.Windows.Forms.ProgressBar
$script:barraAtividade.Dock = 'Fill'
$script:barraAtividade.Style = 'Blocks'
$script:barraAtividade.Margin = [System.Windows.Forms.Padding]::new(1,5,1,6)
$bottom.Controls.Add($script:barraAtividade,0,4)
$script:linkDetalhes = New-Object System.Windows.Forms.LinkLabel
$script:linkDetalhes.Dock = 'Fill'
$script:linkDetalhes.Text = 'Mostrar detalhes e registros'
$script:linkDetalhes.Font = Fonte 8.6
$script:linkDetalhes.LinkColor = $script:azul
$script:linkDetalhes.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
$script:linkDetalhes.TextAlign = 'MiddleLeft'
$script:linkDetalhes.Add_LinkClicked({ DefinirDetalhes (-not $script:logsExpandidos) })
$bottom.Controls.Add($script:linkDetalhes,0,5)
$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Dock='Fill'; $script:txtLog.Multiline=$true
$script:txtLog.ReadOnly=$true; $script:txtLog.ScrollBars='Vertical'
$script:txtLog.Font=[System.Drawing.Font]::new('Consolas',8)
$script:txtLog.BackColor=$script:fundo
$bottom.Controls.Add($script:txtLog,0,6)
$script:logsExpandidos = $false
$script:txtLog.Visible = $false
$script:barra.Visible = $false
$script:barraAtividade.Visible = $false
function DefinirDetalhes([bool]$abrir) {
    $script:logsExpandidos = $abrir
    if ($null -eq $script:txtLog -or $script:txtLog.IsDisposed) { return }
    $script:txtLog.Visible = $abrir
    $script:linkDetalhes.Text = if ($abrir) { 'Ocultar detalhes e registros' } else { 'Mostrar detalhes e registros' }
    # Altera apenas o espaco do rodape, sem interferir na lista de aplicativos.
    $outer.RowStyles[2].Height = if ($abrir) { 256 } else { 165 }
    if ($abrir) { $script:txtLog.SelectionStart = $script:txtLog.TextLength; $script:txtLog.ScrollToCaret() }
}

$script:btnTodos.Add_Click({
    if ($script:executando) { return }
    foreach ($a in @(Visiveis)) { $script:marcados[[string]$a.Chave]=$true }
    MostrarAplicativos; Recontar
})
$script:btnLimpar.Add_Click({
    if ($script:executando) { return }
    $script:marcados.Clear()
    MostrarAplicativos; Recontar
})
$script:btnBaixar.Add_Click({ Executar 'download' })
$script:btnInstalar.Add_Click({ Executar 'install' })
$script:btnAtualizar.Add_Click({ Executar 'upgrade' })
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval=700
$script:timer.Add_Tick({
    if ($script:inventarioRodando) { FinalizarInventario }
    if (-not $script:executando -or $null -eq $script:processo) { return }
    try {
        if (-not $script:processo.HasExited) {
            # Leitura informativa: o WinGet pode nao emitir percentual para todos os pacotes.
            if (Test-Path -LiteralPath $script:logPacote) {
                $textoParcial = (@(Get-Content -LiteralPath $script:logPacote -Tail 12 -ErrorAction SilentlyContinue) -join ' ')
                $fase = 'WinGet em execucao (aguardando resposta do instalador)'
                if ($textoParcial -match '(?i)Installing|Instalando|Starting package install|Iniciando instala') { $fase = 'Instalando...' }
                elseif ($textoParcial -match '(?i)Downloading|Baixando|Download progress') { $fase = 'Baixando...' }
                elseif ($textoParcial -match '(?i)Verifying|Verificando|Installer hash|Hash do instalador') { $fase = 'Verificando...' }
                if ($fase -ne $script:ultimoStatusWinget) {
                    $script:ultimoStatusWinget = $fase
                    DefinirStatus ([string]$script:atual.Chave) $fase
                    $script:lblAtividade.Text = ($script:atual.Nome + ': ' + $fase)
                }
            }
            $tempoGasto = (Get-Date) - $script:inicioPacote
            $tempoFormatado = ('{0:00}:{1:00}' -f [int][Math]::Floor($tempoGasto.TotalMinutes),$tempoGasto.Seconds)
            $ultimoRetorno = 0
            if (Test-Path -LiteralPath $script:logPacote) { $ultimoRetorno = [int]((Get-Date) - (Get-Item -LiteralPath $script:logPacote).LastWriteTime).TotalSeconds }
            $script:lblAtividade.Text = "[$($script:concluidos+1)/$($script:total)] $($script:atual.Nome) - $($script:ultimoStatusWinget) | $tempoFormatado"
            if ($ultimoRetorno -ge 30) { $script:lblAtividade.Text += " | sem nova saida ha $ultimoRetorno s (instalador pode estar trabalhando)" }
            return
        }
        $code = [int64]$script:processo.ExitCode
        $script:processo.Dispose(); $script:processo=$null
        $resultadoEstado = ''
        if (Test-Path -LiteralPath $script:resultadoPacote) {
            try {
                $r=Get-Content -LiteralPath $script:resultadoPacote -Raw -Encoding UTF8 | ConvertFrom-Json
                $code=[int64]$r.Codigo
                $resultadoEstado = [string]$r.Estado
            } catch { Log ('Falha ao ler resultado: ' + $_.Exception.Message) }
        }
        if ($code -eq 0 -and $resultadoEstado -in @('JA_INSTALADO','JA_ATUALIZADO')) {
            $script:jaInstalados++
            $msgAtualizado = if ($resultadoEstado -eq 'JA_ATUALIZADO') { 'Sem nova versao' } else { 'Ja instalado' }
            DefinirStatus ([string]$script:atual.Chave) $msgAtualizado
            Log ($msgAtualizado + ': ' + $script:atual.Nome)
        } elseif ($code -eq 0) {
            $script:sucessos++
            $textoOk = if ($script:operacaoAtual -eq 'download') { 'Baixado' } elseif ($script:operacaoAtual -eq 'upgrade') { 'Atualizado' } else { 'Instalado' }
            DefinirStatus ([string]$script:atual.Chave) $textoOk
            Log ('SUCESSO WinGet: ' + $script:atual.Nome)
        } else {
            $script:falhas++
            DefinirStatus ([string]$script:atual.Chave) 'Falhou - ver log'
            Log ('FALHOU: ' + $script:atual.Nome + '; codigo: ' + $code)
        }
        if (Test-Path -LiteralPath $script:logPacote) {
            $linhas=@(Get-Content -LiteralPath $script:logPacote -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -Last 5)
            foreach ($l in $linhas) { Log ('  ' + $l.Trim()) }
            Log ('Diagnostico completo: ' + $script:logPacote)
            if ($script:operacaoAtual -eq 'download' -and $code -eq 0) { Log ('Arquivos em: ' + (Join-Path (Join-Path $script:pastaDownloads (Split-Path $script:session -Leaf)) ('{0:D3}' -f $script:contador))) }
        }
        $script:concluidos++; Progresso; ProximoPacote
    } catch {
        Log ('Erro ao acompanhar WinGet: ' + $_.Exception.Message)
        $script:falhas++; DefinirStatus ([string]$script:atual.Chave) 'Falhou - ver log'; $script:concluidos++; Progresso; ProximoPacote
    }
})
$form.Add_FormClosing({
    param($sender,$eventArgs)
    if ($script:inventarioRodando -and $script:processoInventario -and -not $script:processoInventario.HasExited) {
        try { $script:processoInventario.Kill() } catch {}
    }
    if ($script:executando) {
        $eventArgs.Cancel=$true
        [void][System.Windows.Forms.MessageBox]::Show('Aguarde a conclusao da operacao antes de fechar.','Operacao em andamento','OK','Information')
    }
})

# Inicializacao intencionalmente nao usa SelectedIndex ou SetSelected.
MostrarAplicativos
Recontar
$script:timer.Start()
Log ("Central v8.5.3 aberta. $($script:apps.Count) programas. Logs em: $($script:session)")
$form.Add_Shown({ IniciarInventario })
try { [void]$form.ShowDialog() }
finally { $script:timer.Stop(); $script:timer.Dispose(); $form.Dispose() }
