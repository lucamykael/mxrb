# Operação, lifecycle e Marketplace

## Diagnóstico, benchmark e evolução

```sh
mxrb doctor .
mxrb doctor . --json
mxrb benchmark App.mpr --iterations 5 --json
mxrb project inspect . --json
mxrb upgrade --mendix 11.12.1 --target .
mxrb upgrade --mendix 11.12.1 --target . --apply
mxrb migrate plan .
mxrb migrate check .
```

`doctor` verifica o projeto Ruby, agregadores, MPR e toolchain disponível.
`benchmark` mede abertura, construção do índice semântico e validação. Upgrade
é preview por padrão; `--apply` altera somente a declaração de versão no
`project.rb`. Migration gera o projeto em área temporária e compara o modelo
resultante com o MPR atual; `check` retorna erro quando existe drift.

## Marketplace Mendix oficial e comunitário

O Marketplace web oficial não oferece um fluxo público completo e estável de
download por PAT. Por isso, o MXRB separa três capacidades:

```sh
mxrb marketplace search CommunityCommons
mxrb marketplace pull CommunityCommons
mxrb marketplace pull github:mendix/CommunityCommons
mxrb marketplace import ./CommunityCommons.mpk --mpr VetClinic.mpr
mxrb marketplace pull CommunityCommons --mpr VetClinic.mpr
mxrb marketplace list
mxrb marketplace verify
```

`pull` resolve releases públicas do GitHub; `import` aceita um MPK oficial já
baixado. Com `--mpr`, o MXRB lê `package.xml` e o `project.mpr` interno, importa
a árvore completa de units diretamente via Ruby/SQLite/BSON e instala os
assets declarados. Não executa `mx`, `mxcli`, Studio Pro nem Model SDK. A
operação preserva IDs, usa transação, restaura assets em falhas, recusa módulo
duplicado e exige a mesma versão de modelo Mendix — conversão entre versões
continuaria exigindo um conversor de metamodelo.

O pacote fica em `.mxrb/marketplace/` e versão, origem, SHA-256, module ID,
units, MPR e assets ficam registrados em `.mxrb/marketplace.lock.json`.
`verify` confere simultaneamente cache, presença do módulo no MPR e assets.
Sem `--mpr`, o comportamento legado continua disponível para extrair arquivos
ZIP de repositórios Ruby-first.
`GITHUB_TOKEN` é opcional para elevar o limite da API pública.

```sh
mxrb marketplace login
```

Login salva o PAT em `~/.config/mxrb/credentials` (ou
`$XDG_CONFIG_HOME/mxrb/credentials`) com permissão `0600`. Esta é a fundação
segura para uma integração autenticada futura; o comando `pull` atual não usa
o PAT para fingir uma API oficial que não foi confirmada.

Há dois marketplaces distintos: `mxrb module search/add` instala módulos Ruby
reutilizáveis do ecossistema MXRB; `mxrb marketplace ...` instala pacotes
Mendix oficiais/comunitários.
