# Programar pelo pendrive (cmd, sem instalar nada)

Abra um `cmd` e rode (a letra muda de PC para PC, troque `E:`):

```
call E:\IA\Menu\ferramentas-dev.cmd
```

Vale só para aquela janela: põe `git`, `python`, `pip`, `node` e `npm` do pendrive
na frente do PATH e aponta configuração e cache para dentro do pendrive. Fechou a janela, acabou.

## O que tem

| Ferramenta | Versão | Onde | Tamanho | Origem conferida |
|---|---|---|---|---|
| Git (PortableGit) | 2.55.0.windows.5 | `Ferramentas\git` | 385 MB, 9.585 arquivos | github.com/git-for-windows, SHA-256 `5aa8a20f6e9abb2c755f0e73c91c687701a46b309ad84a0ca6509380fa4ae290` (igual na página e na API da release) + assinatura Authenticode válida (Johannes Schindelin) |
| Python para projetos | 3.12.10 embeddable + pip 26.2.1 | `Ferramentas\python-projetos` | 85 MB (inclui wheelhouse) | python.org, MD5 `fe8ef205f2e9c3ba44d0cf9954e1abd3` (o que a página publica) + python.exe assinado pela Python Software Foundation; pip pela PyPI, SHA-256 `71138adf1f4ca900cdb7d289c21b7494329f2332b6d85f0e1c42108c0384ed3e` |
| Wheelhouse (offline) | 49 pacotes cp312/win_amd64 | `Ferramentas\python-projetos\wheelhouse` | 53 MB | `pip download` da PyPI (pip confere o hash de cada um); lista em `SHA256SUMS.txt` |
| Node / npm | 22.12.0 / 10.9.0 | `Studio\app\tools\node-win` (o do Studio, já traz npm) | — | já existia |
| Cache do npm | — | `Ferramentas\node\npm-cache` | <1 MB | pacotes do registry.npmjs.org (npm confere sha512) |

O `Python\python312` (usado pelo openzim-mcp) é outro e não foi tocado.

Wheelhouse: requests, pandas, numpy, matplotlib, openpyxl, flask, fastapi, uvicorn, pytest,
python-docx, pypdf (+ dependências, pip, setuptools, wheel).

## Uso

Git (config global fica em `Ferramentas\git\pendrive-gitconfig`, nunca em `%USERPROFILE%\.gitconfig`):
```
git init & git add . & git commit -m "primeiro"
```

Python sem internet, bibliotecas dentro da pasta do projeto:
```
python -m pip install --no-index --target libs pytest pandas
set PYTHONPATH=%CD%\libs;%CD%
python -m pytest
```
(`python -m venv` não existe no Python "embeddable"; o `sitecustomize.py` faz o PYTHONPATH valer.)
Com internet, `pip install` normal também funciona e o cache fica em `python-projetos\pip-cache`.

Node:
```
npm init -y
npm install --offline is-number      (só o que já está no cache)
npm install express                  (com internet; entra no cache do pendrive)
```

## Sem rastro

Variáveis que o script define: `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_NOSYSTEM`, `PIP_CONFIG_FILE=NUL`,
`PIP_CACHE_DIR`, `PIP_FIND_LINKS`, `PYTHONNOUSERSITE`, `npm_config_cache`, `npm_config_prefix`,
`npm_config_userconfig`. Teste de 19/09/2026 com `Testes\rastros.ps1 -Antes/-Depois` em volta de
git init/commit + pip offline + pytest + npm init/install offline: nada novo em `%APPDATA%\npm`,
`%LOCALAPPDATA%\pip`, nem em `%USERPROFILE%\.gitconfig` (hash igual antes e depois).
