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

O MXRB usa a Marketplace Content API documentada pela Mendix. Crie um PAT com
o escopo `mx:marketplace-content:read` e autentique uma vez:

```sh
cp .env.example .env
mxrb marketplace login --pat-file .env
mxrb marketplace search "Community Commons"
mxrb marketplace show 170
mxrb marketplace versions 170 --mendix-version 11.12.1
mxrb marketplace pull 170 --mpr VetClinic.mpr
mxrb marketplace pull 170@3.4.0 --mpr VetClinic.mpr
mxrb marketplace pull github:mendix/CommunityCommons
mxrb marketplace import ./CommunityCommons.mpk --mpr VetClinic.mpr
mxrb marketplace audit --target . --mendix-version 11.12.1
mxrb marketplace list
mxrb marketplace verify
```

Busca oficial inclui conteúdo público e conteúdo privado da empresa visível ao
dono do PAT. Os filtros incluem `--private`, `--public`, `--approved` e
`--published-since AAAA-MM-DD`. `show` apresenta publicador, tipo, suporte,
licença, privacidade e aprovação. `versions` apresenta compatibilidade, release
notes e estados `Regular`, `Vulnerable` e `SecurityFix`, incluindo CVE/CWE.

`pull` oficial é o padrão: seleciona pela API a versão mais recente compatível
com o MPR, usa a URL de download retornada pela API e bloqueia versões vulneráveis, salvo uso explícito
de `--allow-vulnerable`. `github:` continua como fallback e `import` aceita um
MPK local. Com `--mpr`, o MXRB lê `package.xml` e o `project.mpr` interno, importa
a árvore completa de units diretamente via Ruby/SQLite/BSON e instala os
assets declarados. Não executa `mx`, `mxcli`, Studio Pro nem Model SDK. A
operação preserva IDs, usa transação, restaura assets em falhas e recusa módulo
duplicado. Pacotes oficiais compatíveis podem avançar para a versão mais nova
do modelo do projeto; imports locais/GitHub continuam exigindo versão idêntica.
Quando Atlas Core é instalado, o MXRB conecta suas variáveis Sass legadas sem
sobrescrever as customizações do projeto.

O pacote fica em `.mxrb/marketplace/` e versão, origem, Content ID, Version ID,
estado de segurança, SHA-256, module ID, units, MPR e assets ficam registrados
em `.mxrb/marketplace.lock.json`. `audit` consulta atualizações e vulnerabilidades.
`verify` confere simultaneamente cache, presença do módulo no MPR e assets.
Sem `--mpr`, o comportamento legado continua disponível para extrair arquivos
ZIP de repositórios Ruby-first.
`GITHUB_TOKEN` é opcional para elevar o limite da API pública.

```sh
cp .env.example .env
# edite .env e defina MXRB_MENDIX_PAT sem versionar o arquivo
mxrb marketplace login --pat-file .env
```

Por padrão recomendado, o login valida o PAT e salva **somente o caminho
absoluto** do `.env` em `~/.config/mxrb/credentials` (ou
`$XDG_CONFIG_HOME/mxrb/credentials`). O MXRB não copia, move, altera permissões
nem reescreve o arquivo apontado; ele o lê quando uma operação oficial precisa
autenticar. Scaffolds novos já ignoram `.env` e geram `.env.example` sem segredo.

Quem preferir armazenamento gerenciado pode executar
`mxrb marketplace login --store-pat`. Antes de pedir o PAT, o comando informa
que gravará JSON no arquivo global com permissão `0600`. Também é possível usar
`MXRB_MENDIX_PAT_FILE=/caminho/.env` sem persistir configuração. Consulte
`mxrb marketplace login --help` para os formatos e precedência.

O token só é enviado aos hosts oficiais exatos
`marketplace-api.mendix.com` e `marketplace.mendix.com`; ele é removido em
redirects para qualquer outro host. Consulte a
[Marketplace Content API](https://docs.mendix.com/apidocs-mxsdk/apidocs/content-api/).

Há dois marketplaces distintos: `mxrb module search/add` instala módulos Ruby
reutilizáveis do ecossistema MXRB; `mxrb marketplace ...` instala pacotes
Mendix oficiais/comunitários.
