# Central de Aplicativos para Windows

Central de instalação de aplicativos por categorias, usando **PowerShell 5.1 + WinGet**. Mantém a seleção no próprio Windows, sem navegador. A versão v8 acrescenta indicação de status por programa e melhora o progresso.

## Iniciar diretamente com um comando PowerShell (v8.1)

Para um **repositório público**, publique o arquivo `iniciar.ps1` no ramo `main` e edite **uma única vez** a variável `$repositorio` no próprio arquivo, substituindo `SEU-USUARIO/central-aplicativos` pelo proprietário e nome reais.

Depois de publicar a primeira GitHub Release com os arquivos `Central-de-Aplicativos-Windows.zip` e `SHA256SUMS.txt`, o comando abaixo recupera o iniciador pelo GitHub e o executa:

```powershell
irm https://raw.githubusercontent.com/SEU-USUARIO/central-aplicativos/main/iniciar.ps1 | iex
```

**Troque `SEU-USUARIO`** pelo proprietário real. O `iniciar.ps1` baixa a release mais recente, confere o SHA-256 publicado, extrai para pasta temporária, pergunta antes de abrir e inicia a interface localmente em PowerShell STA. O catálogo e a interface não precisam ser reescritos para funcionar via link.

**Atenção à segurança:** `irm ... | iex` executa código remoto imediatamente e não oferece revisão antes da execução. Recomenda-se usá-lo **somente** em um repositório controlado pelo TI, após revisão de código e proteção da branch. O arquivo SHA-256 publicado no mesmo repositório detecta alterações no download, mas **não comprova a identidade de quem publicou o pacote**. Considere assinatura digital para distribuição empresarial. O script não altera as políticas de execução e pode ser bloqueado por regras corporativas.

Alternativa para inspecionar o conteúdo antes de executar:

```powershell
iwr https://raw.githubusercontent.com/SEU-USUARIO/central-aplicativos/main/iniciar.ps1 -OutFile .\iniciar.ps1
notepad .\iniciar.ps1
.\iniciar.ps1
```

Repositório privado exige mecanismo de autenticação e não tem URL pública de download desse tipo.

## Rodar no Windows

Baixe o ZIP de uma release, extraia em uma pasta e execute `Iniciar-Central.cmd`. Faça o primeiro teste com `Testar-Download-7Zip.cmd`; ele baixa o instalador sem instalá-lo. Uma instalação real exige sua confirmação, conexão à internet e permissões adequadas.

> O script foi inspecionado estaticamente, mas ainda precisa de validação em um Windows real. Progresso por pacote é **indeterminado**, não porcentagem real de download. A interface tenta inferir a etapa pelos logs do WinGet, e alguns instaladores não divulgam etapa.

## Editar programas

Edite somente `catalogo.json`. Cada registro representa uma entrada de programa, por exemplo:

```json
{"Grupo":"Utilitarios","Nome":"Exemplo","Id":"Fornecedor.Produto","Tipo":"Normal","Nota":"","Arquitetura":""}
```

Confirme o ID pelo comando `winget show --id Fornecedor.Produto --exact --source winget`. Nunca cole links de instaladores desconhecidos. Para adicionar um **novo grupo**, basta escrever o valor de `Grupo`; ele aparecerá automaticamente.

Execute `python ferramentas/validar_catalogo.py` antes de publicar. O workflow do GitHub também confere a sintaxe PowerShell e gera o pacote ZIP.

## Link único sempre apontando à última release

Para repositório **público**, depois da primeira publicação, use:

```text
https://github.com/SUA-ORGANIZACAO/central-aplicativos/releases/latest/download/Central-de-Aplicativos-Windows.zip
```

Substitua `SUA-ORGANIZACAO` e `central-aplicativos` pelos nomes reais do GitHub. Não é necessário mudar o link a cada release; ele baixa a versão mais recente publicada (não o último commit ainda não publicado). Em repositório **privado**, o acesso exige autenticação e um link público de download não é apropriado.

## Publicar uma atualização

1. Faça a alteração na branch de trabalho e abra um pull request.
2. Confirme a validação e revisão por TI.
3. Integre na `main`, ajuste `VERSION`, crie uma tag como `v8.0.0` e faça push da tag.
4. A Action `Publicar versão aprovada` cria o ZIP, o SHA-256 e uma Release no GitHub.
5. Os colaboradores continuam utilizando o mesmo link `/releases/latest/download/...`.

## Segurança

- Ative autenticação multifator nas contas com permissão de escrita.
- Proteja `main` com revisão de pull requests, verificações obrigatórias e sem push direto.
- Para ambiente corporativo, considere **assinar o PowerShell com Authenticode** e validar a assinatura antes da execução. Um hash baixado do mesmo repositório não protege contra comprometimento da conta que publica a Release.
- Distribuição pelo GitHub não elimina o prompt de confiança, políticas locais ou requisitos de permissões de administrador.
- Não use `irm URL | iex` para baixar e executar scripts remotos automaticamente.
- Os aplicativos do catálogo possuem licenças distintas. Revise licenças e permissões antes do uso empresarial.
- As regras de execução de Windows impostas pela empresa devem ser respeitadas.

## Estrutura

- `iniciar.ps1`: iniciador de um comando via GitHub, que verifica e abre a última release.
- `Central-de-Aplicativos.ps1`: interface e processador de fila.
- `catalogo.json`: lista editável de programas.
- `Iniciar-Central.cmd`: iniciador local.
- `.github/workflows/validar.yml`: testes automáticos de código e catálogo.
- `.github/workflows/publicar.yml`: publicação versionada no GitHub Releases.
- `ferramentas/`: utilitários para validar e empacotar.

**Limitação:** o comando busca a ultima release a cada execucao, mas nao instala atualizacoes silenciosamente; exige confirmacao e respeita as politicas locais.


## Primeira publicacao pelo navegador GitHub

1. Crie o repositorio publico `central-aplicativos` sem README gerado pelo GitHub.
2. Extraia este ZIP; edite `iniciar.ps1`, alterando `$repositorio` para `SEU-USUARIO/central-aplicativos`.
3. Envie o CONTEUDO da pasta extraida, preservando as pastas `.github/workflows` e `ferramentas`.
4. Confira a Action de validacao em Actions.
5. Acesse Releases > Draft a new release; crie a tag `v8.1.0` a partir da `main`, nome `v8.1.0` e publique.
6. O workflow de tag anexa `Central-de-Aplicativos-Windows.zip` e `SHA256SUMS.txt` automaticamente. Verifique os dois anexos ao final.
7. Somente entao execute o iniciador revisado.

A primeira release criada pelo navegador pode inicialmente aparecer sem os anexos ate a Action terminar.
Este projeto nao deve ser distribuido em maquinas de producao antes de validacao em Windows.
