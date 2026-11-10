from pathlib import Path
import json, re, sys
raiz = Path(__file__).resolve().parents[1]
dados = json.loads((raiz/'catalogo.json').read_text(encoding='utf-8-sig'))
assert isinstance(dados, list) and dados, 'Catálogo vazio ou inválido'
vistos = set()
permitidos = {'Normal','Antivirus','BuscaNomeAV','Scanner','Painel'}
for i, item in enumerate(dados, 1):
    assert isinstance(item, dict), f'Entrada {i} precisa ser objeto'
    for k in ['Grupo','Nome','Id','Tipo','Nota','Arquitetura']:
        assert k in item, f'Entrada {i} sem campo {k}'
    assert item['Grupo'].strip() and item['Nome'].strip(), f'Entrada {i} sem nome/grupo'
    assert item['Tipo'] in permitidos, f'Tipo inesperado na entrada {i}'
    if item['Tipo'] not in {'Painel','BuscaNomeAV'}:
        assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.+-]{1,140}', item['Id']), f'Id Winget inválido: {item["Id"]}'
    if item['Tipo'] == 'BuscaNomeAV':
        assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 .+_-]{1,100}', item['Id']), f'Busca inválida: {item["Id"]}'
    if item['Arquitetura']:
        assert item['Arquitetura'] in {'x64','x86','arm64','arm'}, f'Arquitetura inválida: {item["Arquitetura"]}'
    chave = (item['Grupo'].casefold(),item['Nome'].casefold())
    assert chave not in vistos, f'Duplicado: {item["Nome"]}'
    vistos.add(chave)
print(f'Catálogo válido: {len(dados)} aplicativos; {len(set(x["Grupo"] for x in dados))} categorias.')
