from pathlib import Path
import zipfile, hashlib, subprocess, sys
raiz = Path(__file__).resolve().parents[1]
subprocess.check_call([sys.executable, str(raiz / 'ferramentas' / 'validar_catalogo.py')])
pasta = raiz / 'dist'
pasta.mkdir(exist_ok=True)
zip_path = pasta / 'Central-de-Aplicativos-Windows.zip'
arquivos = [
    'Central-de-Aplicativos.ps1', 'catalogo.json', 'Iniciar-Central.cmd',
    'Testar-WinGet.cmd', 'Testar-Download-7Zip.cmd',
    'Testar-Instalacao-7Zip.cmd', 'Testar-Inventario.cmd',
    'Verificar-Catalogo.cmd', 'LEIA-ME.txt', 'VERSION'
]
assets = sorted((raiz / 'assets').rglob('*'))
assert any(f.is_file() for f in assets), 'A pasta assets precisa conter imagens'
with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for nome in arquivos:
        arq = raiz / nome
        assert arq.is_file(), f'Arquivo ausente: {nome}'
        z.write(arq, nome)
    for arq in assets:
        if arq.is_file():
            z.write(arq, arq.relative_to(raiz).as_posix())
sha = hashlib.sha256(zip_path.read_bytes()).hexdigest()
(pasta / 'SHA256SUMS.txt').write_text(f'{sha}  {zip_path.name}\n', encoding='utf-8')
print(f'{zip_path} ({zip_path.stat().st_size} bytes)')
print('SHA256:', sha)
