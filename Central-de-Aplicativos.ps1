# Central de Aplicativos v8.3 - menu local para Windows 10/11
# Requer WinGet para baixar e instalar. Sem site, sem dominio, sem servidor.
# O TI deve conferir scripts e licencas antes de executar. Nao altera a politica de execucao global.
param(
    [switch]$Worker,
    [ValidateSet('install','download')][string]$Operacao = 'install',
    [string]$PacoteId = '', [string]$TipoPacote = '', [string]$ArquiteturaPacote = '',
    [string]$Saida = '', [string]$Resultado = '', [string]$PastaDownload = ''
)

# --- Processo separado: instalacao/download com log e codigo de saida ---
if ($Worker) {
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
        if ($Operacao -eq 'install') { $argsWinget += '--silent' }
        else {
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
$script:ultimoStatusWinget = ''
$script:contador = 0
$script:operacaoAtual = 'install'
$script:session = Join-Path $env:TEMP ('CentralApps-v8.3-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
[void](New-Item -ItemType Directory -Path $script:session -Force)
$script:logFile = Join-Path $script:session 'Central.log'
$script:pastaDownloads = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'CentralApps'
$script:azul = [System.Drawing.Color]::FromArgb(31,88,159)
$script:azulEscuro = [System.Drawing.Color]::FromArgb(24,49,78)
$script:texto = [System.Drawing.Color]::FromArgb(38,53,72)
$script:cinza = [System.Drawing.Color]::FromArgb(105,119,138)
$script:fundo = [System.Drawing.Color]::FromArgb(245,247,251)
$script:borda = [System.Drawing.Color]::FromArgb(226,231,239)

function Fonte([float]$size,[bool]$bold=$false) {
    $style = [System.Drawing.FontStyle]::Regular
    if ($bold) { $style = [System.Drawing.FontStyle]::Bold }
    return [System.Drawing.Font]::new('Segoe UI',$size,$style)
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
        ($term.Length -eq 0 -or ([string]$_.Nome).IndexOf($term,[System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.Nota).IndexOf($term,[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
}
function DefinirStatus([string]$chave,[string]$descricao) {
    $script:statusPorApp[$chave] = $descricao
    if ($script:listaApps -and -not $script:listaApps.IsDisposed) {
        foreach ($card in $script:listaApps.Controls) {
            foreach ($control in $card.Controls) {
                if ($control -is [System.Windows.Forms.Label] -and [string]$control.Tag -eq ('status:' + $chave)) {
                    $control.Text = $descricao
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
    $script:btnInstalar.Enabled = (-not $script:executando -and $number -gt 0 -and $abaAplicativos)
}
function ReestilizarCategorias {
    foreach ($ctrl in $script:grupoPanel.Controls) {
        if ([string]$ctrl.Tag -eq $script:grupoAtivo) {
            $ctrl.BackColor = [System.Drawing.Color]::FromArgb(225,236,251)
            $ctrl.ForeColor = $script:azul
        } else {
            $ctrl.BackColor = [System.Drawing.Color]::White
            $ctrl.ForeColor = $script:texto
        }
    }
}
function AtualizarLargura {
    $w = [Math]::Max(380, [int]$script:listaApps.ClientSize.Width - 29)
    foreach ($ctrl in $script:listaApps.Controls) { $ctrl.Width = $w }
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
            $card = New-Object System.Windows.Forms.Panel
            $card.Width = $w
            $temAvisoLicenca = -not [string]::IsNullOrWhiteSpace([string]$app.AvisoLicenca)
            $card.Height = if ($temAvisoLicenca) { 82 } else { 60 }
            $card.Margin = [System.Windows.Forms.Padding]::new(3,3,3,2)
            $card.BackColor = [System.Drawing.Color]::White
            $box = New-Object System.Windows.Forms.CheckBox
            $box.Location = [System.Drawing.Point]::new(12,7)
            $box.Width = [Math]::Max(180,$w-240)
            $box.Height = 26
            $box.Tag = [string]$app.Chave
            $box.Text = [string]$app.Nome
            $box.Font = Fonte 10 $true
            $box.ForeColor = $script:texto
            $box.Checked = $script:marcados.ContainsKey([string]$app.Chave)
            $box.Add_CheckedChanged({
                param($sender,$eventArgs)
                if ($script:atualizando -or $script:executando) { return }
                $key = [string]$sender.Tag
                if ($sender.Checked) { $script:marcados[$key] = $true }
                else { [void]$script:marcados.Remove($key) }
                Recontar
            })
            [void]$card.Controls.Add($box)
            $estadoLabel = New-Object System.Windows.Forms.Label
            $estadoLabel.Tag = 'status:' + [string]$app.Chave
            $estadoLabel.Text = if ($script:statusPorApp.ContainsKey([string]$app.Chave)) { [string]$script:statusPorApp[[string]$app.Chave] } else { 'Pendente' }
            $estadoLabel.Location = [System.Drawing.Point]::new(($w-195),10)
            $estadoLabel.Width = 178; $estadoLabel.Height = 21
            $estadoLabel.TextAlign = 'MiddleRight'
            $estadoLabel.AutoEllipsis = $true
            $estadoLabel.ForeColor = $script:azul
            $estadoLabel.Font = Fonte 8.5 $true
            [void]$card.Controls.Add($estadoLabel)
            $descricao = New-Object System.Windows.Forms.Label
            $descricao.Text = [string]$app.Nota
            if (-not $descricao.Text) { $descricao.Text = 'Instalacao pelo WinGet.' }
            $descricao.Location = [System.Drawing.Point]::new(36,34)
            $descricao.AutoEllipsis = $true
            $descricao.Width = [Math]::Max(270,$w-55)
            $descricao.Height = 19
            $descricao.ForeColor = $script:cinza
            $descricao.Font = Fonte 8.5
            [void]$card.Controls.Add($descricao)
            if ($temAvisoLicenca) {
                $aviso = New-Object System.Windows.Forms.Label
                $aviso.Text = 'LICENCA: ' + [string]$app.AvisoLicenca
                $aviso.Location = [System.Drawing.Point]::new(36,54)
                $aviso.Width = [Math]::Max(270,$w-55)
                $aviso.Height = 19
                $aviso.AutoEllipsis = $true
                $aviso.ForeColor = [System.Drawing.Color]::FromArgb(155,85,24)
                $aviso.Font = Fonte 8.3 $true
                $aviso.Tag = 'Licenciamento: ' + [string]$app.UrlLicenca
                $tipLicenca = New-Object System.Windows.Forms.ToolTip
                $tipLicenca.SetToolTip($aviso, ($aviso.Text + "`r`n" + [string]$app.UrlLicenca))
                [void]$card.Controls.Add($aviso)
            }
            [void]$script:listaApps.Controls.Add($card)
        }
        $script:lblResultados.Text = "$($visiveis.Count) de $($script:apps.Count) programas"
        ReestilizarCategorias
    } finally {
        $script:listaApps.ResumeLayout()
        $script:atualizando = $false
    }
}
function Bloquear([bool]$state) {
    $script:executando = $state
    $script:btnTodos.Enabled = -not $state
    $script:btnLimpar.Enabled = -not $state
    $script:txtPesquisa.Enabled = -not $state
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
    $script:lblAtividade.Text = 'Sem operacao ativa.'
    $script:lblEstado.Text = "Concluido: $($script:sucessos) sucesso(s), $($script:jaInstalados) ja instalado(s), $($script:falhas) falha(s)."
    Log "Concluido: $($script:sucessos) sucesso(s), $($script:jaInstalados) ja instalado(s), $($script:falhas) falha(s)."
    [void][System.Windows.Forms.MessageBox]::Show("Operacao concluida.`r`nSucessos: $($script:sucessos)`r`nJa instalados: $($script:jaInstalados)`r`nFalhas: $($script:falhas)`r`n`r`nDetalhes: $($script:session)", 'Central de Aplicativos', 'OK', 'Information')
}
function ProximoPacote {
    if ($script:fila.Count -eq 0) { FimDaFila; return }
    $script:atual = $script:fila.Dequeue()
    $app = $script:atual
    DefinirStatus ([string]$app.Chave) 'Iniciando...'
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
        if ($operacao -eq 'download' -and @($lista | Where-Object {$_.Tipo -eq 'Painel'}).Count -gt 0) {
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
        $desc = if ($operacao -eq 'download') { 'BAIXAR APENAS' } else { 'BAIXAR E INSTALAR' }
        $msg = "$desc $($lista.Count) programa(s)?`r`n`r`nFonte: WinGet (winget).`r`nOs aplicativos pertencem aos seus fabricantes e o uso depende de suas licencas.`r`nO WinGet pode aceitar acordos de pacote automaticamente durante a operacao.`r`nAlguns pacotes exigem permissao administrativa ou nao oferecem modo silencioso.`r`n`r`nContinuar?"
        if ([System.Windows.Forms.MessageBox]::Show($msg,'Confirmacao','YesNo','Question') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $script:operacaoAtual = $operacao
        $script:fila.Clear()
        foreach ($a in $lista) { $script:fila.Enqueue($a) }
        $script:total = $lista.Count
        $script:concluidos = 0; $script:sucessos=0; $script:jaInstalados=0; $script:falhas=0; $script:contador=0
        foreach ($a in $lista) { DefinirStatus ([string]$a.Chave) 'Na fila' }
        $script:barra.Value = 0
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
$form.Text = 'Central de Aplicativos - TI | v8.3'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = [System.Drawing.Size]::new(1120,730)
$form.MinimumSize = [System.Drawing.Size]::new(880,620)
$form.BackColor = $script:fundo
$form.Font = Fonte 9.5
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$outer = New-Object System.Windows.Forms.TableLayoutPanel
$outer.Dock = 'Fill'
$outer.ColumnCount = 1; $outer.RowCount = 3
[void]$outer.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,80))
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,205))
[void]$form.Controls.Add($outer)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Fill'; $header.BackColor = $script:azulEscuro
$header.Margin = [System.Windows.Forms.Padding]::new(0)
$h1 = New-Object System.Windows.Forms.Label
$h1.Text = 'CENTRAL DE APLICATIVOS'
$h1.Font = Fonte 17 $true; $h1.ForeColor = [System.Drawing.Color]::White
$h1.Location = [System.Drawing.Point]::new(24,12); $h1.AutoSize = $true
[void]$header.Controls.Add($h1)
$h2 = New-Object System.Windows.Forms.Label
$h2.Text = 'Instalacao via WinGet. Programas de terceiros sujeitos as licencas dos fabricantes.'
$h2.ForeColor = [System.Drawing.Color]::FromArgb(209,226,246)
$h2.Font = Fonte 9.5; $h2.Location = [System.Drawing.Point]::new(26,51); $h2.AutoSize = $true
[void]$header.Controls.Add($h2)
$outer.Controls.Add($header,0,0)

$center = New-Object System.Windows.Forms.TableLayoutPanel
$center.Dock = 'Fill'; $center.ColumnCount = 2; $center.RowCount = 1
$center.Margin = [System.Windows.Forms.Padding]::new(12,12,12,7)
[void]$center.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,210))
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
$side.Dock='Fill'; $side.BackColor=[System.Drawing.Color]::White
$side.Margin = [System.Windows.Forms.Padding]::new(0,0,9,0)
$sideTitle = New-Object System.Windows.Forms.Label
$sideTitle.Text = 'CATEGORIAS'; $sideTitle.Font = Fonte 10 $true
$sideTitle.Location = [System.Drawing.Point]::new(12,12)
$sideTitle.AutoSize = $true
[void]$side.Controls.Add($sideTitle)
$script:grupoPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$script:grupoPanel.Location = [System.Drawing.Point]::new(5,40)
$script:grupoPanel.Size = [System.Drawing.Size]::new(190,510)
$script:grupoPanel.Anchor = 'Top,Bottom,Left,Right'
$script:grupoPanel.AutoScroll = $true
$script:grupoPanel.WrapContents = $false
$script:grupoPanel.FlowDirection = 'TopDown'
[void]$side.Controls.Add($script:grupoPanel)
foreach ($g in $script:grupos) {
    $nome = if ($script:gruposBonitos.ContainsKey($g)) { $script:gruposBonitos[$g] } else { $g }
    $num = if ($g -eq 'Todos os programas') { $script:apps.Count } else { @($script:apps | Where-Object { $_.Grupo -eq $g }).Count }
    $b = New-Object System.Windows.Forms.Button
    $b.Text = "$nome ($num)"; $b.Tag = $g
    $b.Width = 174; $b.Height = 31
    $b.Font = Fonte 8.6
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.TextAlign = 'MiddleLeft'
    $b.Margin = [System.Windows.Forms.Padding]::new(0,1,0,1)
    $b.Add_Click({
        param($sender,$eventArgs)
        if ($script:executando) { return }
        $script:grupoAtivo = [string]$sender.Tag
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
$searchArea.Dock='Fill'; $searchArea.ColumnCount=2; $searchArea.RowCount=2
$searchArea.Padding = [System.Windows.Forms.Padding]::new(13,5,13,5)
[void]$searchArea.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$searchArea.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,170))
[void]$searchArea.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,25))
[void]$searchArea.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
$lblPesquisa = New-Object System.Windows.Forms.Label
$lblPesquisa.Text='PESQUISAR'; $lblPesquisa.ForeColor=$script:cinza
$lblPesquisa.Font=Fonte 8.6 $true; $lblPesquisa.Dock='Fill'
$searchArea.Controls.Add($lblPesquisa,0,0)
$script:lblResultados=New-Object System.Windows.Forms.Label
$script:lblResultados.Dock='Fill'; $script:lblResultados.TextAlign='MiddleRight'
$script:lblResultados.ForeColor=$script:cinza; $script:lblResultados.Font=Fonte 8.6
$searchArea.Controls.Add($script:lblResultados,1,0)
$script:txtPesquisa = New-Object System.Windows.Forms.TextBox
$script:txtPesquisa.Dock='Fill'; $script:txtPesquisa.Font=Fonte 11
$searchArea.Controls.Add($script:txtPesquisa,0,1)
$searchArea.SetColumnSpan($script:txtPesquisa,2)
$main.Controls.Add($searchArea,0,0)
$script:listaApps=New-Object System.Windows.Forms.FlowLayoutPanel
$script:listaApps.Dock='Fill'; $script:listaApps.AutoScroll=$true
$script:listaApps.WrapContents=$false
$script:listaApps.FlowDirection='TopDown'
$script:listaApps.BackColor=$script:fundo
$script:listaApps.Padding=[System.Windows.Forms.Padding]::new(7,4,7,4)
$main.Controls.Add($script:listaApps,0,1)
$script:txtPesquisa.Add_TextChanged({ if (-not $script:executando) { MostrarAplicativos } })
$script:listaApps.Add_SizeChanged({ if (-not $script:atualizando) { AtualizarLargura } })

$bottom = New-Object System.Windows.Forms.TableLayoutPanel
$bottom.Dock='Fill'; $bottom.Margin=[System.Windows.Forms.Padding]::new(0)
$bottom.BackColor=[System.Drawing.Color]::White
$bottom.Padding=[System.Windows.Forms.Padding]::new(12,6,12,8)
$bottom.ColumnCount=1; $bottom.RowCount=6
[void]$bottom.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,54))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,25))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,18))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,23))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Absolute,11))
[void]$bottom.RowStyles.Add([System.Windows.Forms.RowStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
$outer.Controls.Add($bottom,0,2)
$actions = New-Object System.Windows.Forms.TableLayoutPanel
$actions.Dock='Fill'; $actions.RowCount=1; $actions.ColumnCount=5
[void]$actions.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent,100))
[void]$actions.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,135))
[void]$actions.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,135))
[void]$actions.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,155))
[void]$actions.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute,215))
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
$script:btnInstalar = Botao 'BAIXAR E INSTALAR' $true
$actions.Controls.Add($script:btnInstalar,4,0)
$script:lblEstado = New-Object System.Windows.Forms.Label
$script:lblEstado.Dock='Fill'; $script:lblEstado.TextAlign='MiddleLeft'
$script:lblEstado.Text='Pronto. Selecione um programa para iniciar.'
$script:lblEstado.ForeColor=$script:cinza
$bottom.Controls.Add($script:lblEstado,0,1)
$script:barra = New-Object System.Windows.Forms.ProgressBar
$script:barra.Dock='Fill'; $script:barra.Maximum=100
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
$bottom.Controls.Add($script:barraAtividade,0,4)
$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Dock='Fill'; $script:txtLog.Multiline=$true
$script:txtLog.ReadOnly=$true; $script:txtLog.ScrollBars='Vertical'
$script:txtLog.Font=[System.Drawing.Font]::new('Consolas',8)
$script:txtLog.BackColor=$script:fundo
$bottom.Controls.Add($script:txtLog,0,5)

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
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval=700
$script:timer.Add_Tick({
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
        if ($code -eq 0 -and $resultadoEstado -eq 'JA_INSTALADO') {
            $script:jaInstalados++
            DefinirStatus ([string]$script:atual.Chave) 'Ja instalado'
            Log ('JA INSTALADO: ' + $script:atual.Nome)
        } elseif ($code -eq 0) {
            $script:sucessos++
            $textoOk = if ($script:operacaoAtual -eq 'download') { 'Baixado' } else { 'Instalado / atualizado' }
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
    if ($script:executando) {
        $eventArgs.Cancel=$true
        [void][System.Windows.Forms.MessageBox]::Show('Aguarde a conclusao da operacao antes de fechar.','Operacao em andamento','OK','Information')
    }
})

# Inicializacao intencionalmente nao usa SelectedIndex ou SetSelected.
MostrarAplicativos
Recontar
$script:timer.Start()
Log ("Central v8.3 aberta. $($script:apps.Count) programas. Logs em: $($script:session)")
try { [void]$form.ShowDialog() }
finally { $script:timer.Stop(); $script:timer.Dispose(); $form.Dispose() }
