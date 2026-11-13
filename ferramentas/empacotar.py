from pathlib import Path
import zipfile
import hashlib
import subprocess
import sys

raiz = Path(__file__).resolve().parents[1]
subprocess.check_call([sys.executable, str(raiz / 'ferramentas' / 'validar_catalogo.py')])

arquivos = [
    'Central-de-Aplicativos.ps1', 'Manutencao-Drivers.ps1',
    'Auditar-Todos-Os-Pacotes.ps1', 'catalogo.json',
    'Iniciar-Central.cmd', 'LEIA-ME.txt', 'VERSION',
    'Testar-WinGet.cmd', 'Testar-Download-7Zip.cmd',
    'Testar-Instalacao-7Zip.cmd', 'Testar-Inventario.cmd',
    'Verificar-Catalogo.cmd', 'Verificar-Todos-Os-Pacotes.cmd'
]
for nome in arquivos:
    assert (raiz / nome).is_file(), f'Arquivo ausente: {nome}'

assets = sorted(p for p in (raiz / 'assets' / 'icons').rglob('*.png') if p.is_file())
assert assets, 'Os icones da Central estao ausentes em assets/icons'

versao = (raiz / 'VERSION').read_text(encoding='utf-8').strip()
assert versao, 'VERSION esta vazio'

pasta = raiz / 'dist'
pasta.mkdir(exist_ok=True)
zip_path = pasta / 'Central-de-Aplicativos-Windows.zip'
with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for nome in arquivos:
        z.write(raiz / nome, nome)
    for asset in assets:
        z.write(asset, asset.relative_to(raiz).as_posix())

with zipfile.ZipFile(zip_path) as z:
    erro = z.testzip()
    assert erro is None, f'Pacote ZIP invalido: {erro}'
    for nome in arquivos:
        assert nome in z.namelist(), f'Pacote nao incluiu {nome}'

sha = hashlib.sha256(zip_path.read_bytes()).hexdigest()
(pasta / 'SHA256SUMS.txt').write_text(f'{sha}  {zip_path.name}\n', encoding='utf-8')
print(f'Pacote v{versao}: {zip_path} ({zip_path.stat().st_size} bytes)')
print('SHA256:', sha)
