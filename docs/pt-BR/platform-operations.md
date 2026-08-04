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

## Migração e aceitação do frontend

```sh
mxrb frontend migrate App.mpr --json
mxrb frontend migrate App.mpr --apply --json
script/frontend_acceptance App.mpr -o frontend-round-trip.json
script/frontend_acceptance App.mpr --mxbuild /caminho/mxbuild -o frontend.json
script/frontend_acceptance App.mpr --mx /caminho/mx -o frontend-diagnostics.json
script/frontend_lifecycle_acceptance --version 11.12.1 --mx /caminho/mx \
  --mxbuild /caminho/mxbuild --strict-warnings -o frontend-lifecycle.json
```

`mxrb frontend migrate` é uma prévia imutável e fail-closed por padrão. Para
Mendix 10 e 11, planeja a atualização dos schemas dos pluggable widgets
instalados, dos pesos legados de linhas de layout e das design properties a
partir do XML do pacote. `--apply` grava somente um plano seguro em uma única
transação no MPR; propriedades configuradas desconhecidas, geração não
suportada ou unit alterada depois da prévia bloqueiam a escrita. Nem a prévia
nem a aplicação executam ferramentas Mendix.

`script/frontend_acceptance` é o gate reproduzível de 10/11. Ele valida os MPRs
de origem e reconstruído, exige preflight nativo compatível em ambos, exporta
para Ruby e reconstrói, compara a estrutura do modelo e verifica
inventários completos de assets, bytes, SHA-256 e proveniência do Marketplace.
A fronteira de proveniência inclui `.mxrb/marketplace.lock.json`, o cache de
pacotes e `.mxrb/marketplace-originals`; arquivo ausente, alterado ou inesperado
reprova o gate. A matriz aceita do renderer agora cobre tabelas de Forms,
`ListViewXPathSource`, propriedades de objeto de listen target, mappings
estruturados de variáveis de página e enumerações de Combo box. O baseline do
preflight caiu de 28 para 0 achados no 10.24 e de 20 para 0 no 11.12.

Sem `--mxbuild`, o relatório tem escopo `round_trip` e deixa `frontend_ready`
sem valor. Com `--mxbuild`, o MxBuild atua como oráculo externo somente leitura
e o escopo passa a `frontend`; ele nunca gera, altera ou repara o projeto.
O oráculo ao vivo só aceita sucesso quando o MxBuild termina com status zero e
produz um MDA não vazio; falha não zero da toolchain sem erros de modelo
registrados falha fechada em vez de certificar um modelo limpo.
Em 4 de agosto de 2026, a migração segura concluiu a matriz aceita 10.24.0.73019 e
11.12.1: origem e reconstrução retornaram zero erros no MxBuild e os dois
relatórios marcaram `frontend_ready` como `true`.

`script/frontend_lifecycle_acceptance` cria um app exclusivamente pela CLI,
gera o MPR, exporta-o para Ruby, altera a Home e a navegação, adiciona entidade,
formulário, microflow, nanoflow e asset, gera novamente, exporta uma segunda vez
e exige reconstrução estruturalmente idêntica. Na matriz oficial 10.24.0.73019
e 11.12.1, origem e reconstrução concluíram com zero erros, warnings,
depreciações e recomendações no `mx check`, além de zero erros no MxBuild.

`--mx` executa o checker oficial somente leitura com warnings, depreciações e
recomendações de boas práticas. O gate valida o bitmask de saída e compara as
assinaturas normalizadas de origem e reconstrução. A fixture 10.24 aceita tem
0 erros, 173 warnings dos pacotes, 0 depreciações e 2 recomendações do Kafka;
a 11.12 tem 0 erros, 10 warnings dos pacotes, 0 depreciações e as mesmas 2
recomendações. Os JSONs de origem e reconstrução são idênticos byte a byte nas
duas gerações; esses diagnósticos observáveis dos pacotes não são drift do MXRB.

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
mxrb marketplace dependencies CommunityCommons --mpr VetClinic.mpr
mxrb marketplace dependencies CommunityCommons --mpr VetClinic.mpr --apply
mxrb marketplace dependencies CommunityCommons --mpr VetClinic.mpr --apply-resolved
mxrb marketplace update 170@3.5.0 --mpr VetClinic.mpr
mxrb marketplace update 170@3.5.0 --mpr VetClinic.mpr --apply
mxrb marketplace remove CommunityCommons --mpr VetClinic.mpr
mxrb marketplace remove CommunityCommons --mpr VetClinic.mpr --apply
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

`marketplace dependencies` descobre referências qualificadas não resolvidas no
MPR interno do pacote, resolve o grafo recursivamente pela API oficial, baixa
cada candidato e só o aceita quando o próprio MPK comprova a identidade do
módulo solicitado. Módulos pertencentes ao projeto satisfazem referências sem
serem rotulados como pacotes do Marketplace. O padrão é preview; `--apply`
exige grafo completo e seguro, instala folhas primeiro e faz rollback, enquanto
`--apply-resolved` é a opção explícita para aplicar apenas a parte comprovada e
ainda retorna estado bloqueado para identidades não resolvidas.

Em 4 de agosto de 2026, a aceitação autenticada importou Kafka 2.12.0 (Content
ID 105878) e resolveu o grafo oficial em 10.24.0.73019 e 11.12.1. Os dois grafos
importaram DataWidgets 3.11.3 com Content ID 116540 e Version ID
`e7b6d703-8e47-42f4-bb92-934e3601e71b`. O Combo box autenticado final é o
componente oficial independente Widget/clientModule 219304, versão 2.9.0,
Version ID `dce845f4-d051-4161-847c-016c01703caa`. Sua instalação faz backup e
substitui o asset Combo 2.6.x anterior trazido pelo Atlas Core (Content ID
117187); o Atlas é o proprietário anterior do asset, não o componente Combo.
O grafo 11.12 também inclui Library Logging 1.13.0, Encryption 11.1.1, Mx Model
Reflection 9.1.0 e Mendix Feedback Module 5.0.0 (Content ID 205506). Como o
índice por nome da API não expõe `FeedbackModule`, o MXRB usa o ID oficial
somente como dica de descoberta e ainda exige que o MPK baixado prove o nome
interno.

As duas gerações agora passam no gate completo de aceitação do frontend com
zero achados no preflight da origem e da reconstrução, equivalência estrutural,
assets e proveniência do Marketplace exatos e zero erros no MxBuild. O
export/rebuild Ruby preserva o lock do Marketplace, MPKs em cache, originais,
assets declarados e seus checksums; assim, o projeto reconstruído mantém a proveniência dos pacotes,
e não apenas os bytes dos widgets. A trilha segura de migração e os oráculos
externos MxBuild/`mx check` estão concluídos na matriz suportada. Essas
ferramentas continuam sendo apenas validação externa, nunca dependências da
implementação MXRB.

`update` e `remove` oficiais são prévias seguras sem `--apply`. Antes de
alterar o projeto, o MXRB compara módulo e contagem de units do lock com o
pacote em cache, varre todas as units externas em busca de referências a IDs
que desapareceriam e recusa assets alterados ou ausentes. Um update precisa
preservar o ID do módulo e todo ID referenciado externamente. Ao aplicar, o MXRB
protege MPR, `mprcontents` v2, lock, caches, assets declarados e arquivo de
variáveis do Atlas; qualquer falha restaura toda essa fronteira. Assets
compartilhados não são removidos enquanto outro pacote no lock os declarar.

Há dois marketplaces distintos: `mxrb module search/add` instala módulos Ruby
reutilizáveis do ecossistema MXRB; `mxrb marketplace ...` instala pacotes
Mendix oficiais/comunitários.

## Auditoria de conectores de protocolo

`mxrb protocols` é uma auditoria somente leitura dos conectores de IoT,
industriais e de mensageria que um projeto importou do Marketplace. Ele nunca
executa um protocolo e nunca instala nada; apenas relata os metadados públicos
que o modelo expõe.

```sh
mxrb protocols App.mpr
mxrb protocols App.mpr --json
```

Os conectores reconhecidos aparecem com nome do módulo, protocolo e id do
componente no Marketplace; os módulos de marketplace não reconhecidos são
listados à parte. O reconhecimento é por `AppStoreGuid` verificado, então um
módulo cujo GUID não foi confirmado em fixture real ou metadado oficial é
relatado como não reconhecido, nunca inferido.

Este registro de protocolos é um terceiro catálogo, distinto dos módulos Ruby
reutilizáveis de `mxrb module` e dos pacotes oficiais de `mxrb marketplace`.

Os ids públicos verificados atualmente cobrem MQTT, OPC-UA, Kafka, AMQP e
WebSocket. Consultas autenticadas à Content API e ao catálogo oficial ainda não
retornam componente Modbus; por isso ele continua sem cadastro até que um
componente oficial ou uma fixture MPR real comprove sua identidade. O id
público serve para planejamento; o reconhecimento dentro de um MPR ainda exige
`AppStoreGuid` verificado.

O builder Ruby pode declarar a intenção de instalação sem escrever módulo vazio
nem GUID inventado:

```ruby
builder.connector :kafka, version: "2.12.0"
planos = builder.connector_plans(adapter: Mxrb::Protocols.adapter(installer:, api:))
planos.each { puts _1.changes }
planos.each(&:apply!) # operação autenticada e explícita no Marketplace
```

Sem o adapter, `connector_plans` é somente prévia. `build!` também falha fechado
enquanto houver declarações pendentes: o conteúdo real deve ser instalado no
MPR pelo adapter oficial. Entradas `Module` e `Service` podem ser resolvidas,
mas o MPK baixado ainda precisa passar independentemente pelas validações de
fronteira de pacote de módulo.
