# Portabilidade real entre Ruby, TypeScript e Mendix

## Conversão de datas numéricas em UTC

`parseDateTimeUTC(texto, formato[, alternativa])` funciona em microflows Ruby e
nanoflows TypeScript sem acesso ao MPR. Aceita campos numéricos de ano, mês, dia,
hora, minuto, segundo e milissegundo, literais entre aspas e campos adjacentes.
Os anos ficam limitados a 1800–9999. Uma entrada inválida retorna a alternativa
opcional de data/vazio ou gera erro; formatos não suportados sempre geram erro.

Vinte casos foram comparados nos dois modos de execução do Mendix 11.12.1, com
o projeto original e o reconstruído. Ambos rejeitam componentes inválidos.
Microflows aceitam um prefixo válido e deslocamentos numéricos de fuso; nanoflows
rejeitam texto excedente e os formatos de deslocamento testados. Entradas contendo
somente horário usam 1970-01-01 em microflows e a data UTC atual em nanoflows.
Essas diferenças observadas foram preservadas. Nomes localizados, anos com dois
dígitos e `parseDateTime` em horário local ficam fora deste escopo.

A suíte Ruby passou nos 2.345 exemplos, com 100% de cobertura de linhas e
ramificações; o frontend passou em 190 testes e 81 passos no navegador sem MPR.
[Evidência](../evidence/parse-datetime-utc-2026-10-07.json).

## Gravação de objetos do Feedback

`JS_SetFeedbackStorageObject` e `SetStorageItemObject` usam adaptadores Web
selecionados pelo hash da fonte. Os nomes dos parâmetros são preservados:
`key`/`value` na primeira ação e `Key`/`Value` na segunda.

O JSON contém `guid`, números como texto, datas em milissegundos e referências
qualificadas por módulo. Valores falsos, nulos e strings vazias são preservados;
objetos relacionados são representados por identificadores. A ação usa o schema
Ruby atual e não altera o objeto recebido. Snapshots incompletos, membros sem
schema e inteiros que já excedem a precisão exata do frontend geram erro explícito.

As duas gravações coincidiram com o Mendix em dois builds e dois runtimes.
Também passaram 12 comparações com o JavaScript original, dois nanoflows reais
sem alterações e 25 passos no navegador sem MPR. A leitura/recriação de objetos,
`AsyncStorage` e sincronização offline continuam pendentes.
[Evidência](../evidence/feedback-object-storage-2026-10-07.json).

## Atualização de parâmetros de página

Quando uma alteração atualiza o objeto de contexto, referências ao mesmo objeto
nos parâmetros nomeados da página recebem o estado atual. Isso mantém data views,
classes condicionais e argumentos de ações sincronizados após nanoflows e
microflows. Outros objetos, valores primitivos e argumentos vazios são preservados.

A regressão reproduzia o modo de anotações do Sudoku: o valor mudava, mas a página
continuava mostrando a cópia inicial. O fluxo real passou em 32 passos sem acesso
ao MPR; o caso isolado cobre alternâncias e atualização por microflow em 19 passos.
[Evidência](../evidence/live-page-parameters-2026-10-07.json).

## Feedback legado e constantes no frontend

`JS_GetSingleLocalStorageObjectItem`, usado por Sudoku e RubyBridgeSandbox,
recebe um adaptador selecionado pelo SHA-256 da fonte. Ele usa os parâmetros
do modelo `LocalStorageKey` e `ObjectItemKey` e preserva o retorno `""` quando
o item está ausente, diferente do getter mais novo que retorna `null`.

Expressões frontend resolvem `@Module.Constant` a partir das definições Ruby
atuais expostas ao cliente. Constantes privadas e excluídas não entram no schema;
inteiros, booleanos e decimais mantêm seus tipos. A carga da aplicação substitui
o registro anterior; referências indisponíveis geram erro explícito.

Os nanoflows exportados, sem alterações, dos dois projetos reais passaram com
armazenamento ausente, vazio e preenchido. O fixture usa uma constante como
chave e verifica o mesmo comportamento no Ruby e no Mendix.
[Evidência](../evidence/legacy-feedback-2026-10-07.json).

## Geração de views OQL consultáveis

Declarar `oql_view` preserva a flag de persistência da entidade. Views novas
usam o padrão persistente exigido pelo Mendix para consultas de banco; a fonte
OQL continua impedindo a criação de uma tabela física no SQLite. A geração
anterior forçava `Persistable=false` e o MxBuild rejeitava atividades de consulta.
Dois builds e dois runtimes na VM passaram após a correção, com original e
reconstruído retornando o mesmo resultado e hashes preservados.
[Evidência](../evidence/oql-view-persistence-2026-10-07.json).

O runtime Ruby também consulta projeções simples de uma entidade persistente:
colunas com aliases opcionais e `ID` projetado como associação de referência.
As views leem valores salvos, refletem commits e exclusões e rejeitam gravações.
O texto OQL é validado e nunca executado diretamente como SQL. Joins, filtros,
agregações e encadeamento de views ainda não são suportados e geram erro explícito.
Oito resultados coincidiram entre Ruby e os dois runtimes Mendix; 41 passos de
navegador passaram sem acesso ao MPR. A consulta aos modelos dos oito projetos
reais passou nas 98 entidades, incluindo `MyFirstModule.LocationsView`.
[Evidência de execução](../evidence/oql-view-execution-2026-10-07.json).

## Armazenamento Nanoflow Commons

`GetStorageItemString`, `SetStorageItemString`, `RemoveStorageItem`,
`StorageItemExists` e `ClearLocalStorage` têm adaptadores Web selecionados por
SHA-256 da fonte original. Os parâmetros do modelo são `Key` e `Value`.
Preservam os erros de chave/valor obrigatório, a distinção entre chave ausente
e string armazenada vazia, remoção e limpeza. `ClearLocalStorage` limpa todo o
armazenamento da origem atual, como a ação original.

Validação: 60 comparações com o JavaScript original, 176 testes frontend,
51 passos no Chromium sem acesso ao MPR e dois builds/dois runtimes na VM
Windows, com resultados idênticos ao Ruby e hashes preservados. A suíte Ruby
passou 2.326 exemplos com cobertura de linhas e branches de 100%. O Sudoku
real passou auditoria e reconstrução idêntica.
[Evidência](../evidence/commons-storage-2026-10-07.json).
O escopo é `localStorage` Web; `AsyncStorage` React Native ainda não está implementado.

## Ações Nanoflow Commons e listas

O exportador registra `Base64Encode`, `Base64Decode`, `GetGuid`, `GetPlatform`
e `FindObjectWithGUID` somente quando o hash da implementação corresponde à
fonte verificada. Base64 usa `js-base64` 3.7.7, a versão da referência nativa.
O registro preserva o parâmetro `EntityObject` e mantém simultaneamente os
adaptadores Feedback. Nanoflows exportados também executam criação de listas
e adição, remoção e limpeza de objetos, preservando referências à mesma lista.

A validação passou 22 comparações com o JavaScript original, 169 testes de
frontend e 13 etapas no Chromium sem MPR. Dois builds e dois runtimes na VM
confirmaram os mesmos resultados no original e na reconstrução, sem modificar
as fontes. O cenário certifica a plataforma Web; classificação de ambiente
não equivale à certificação de aplicativos React Native ou Cordova.
[Evidências](../evidence/nanoflow-commons-2026-10-07.json).

## CustomChart com Plotly

O `CustomChart` usa Plotly 3.0.1, carregado sob demanda, para aplicar os dados,
o layout e a configuração JSON declarados no modelo. Séries estáticas e de
atributo são concatenadas; alterações no contexto redesenham o gráfico.
Dimensões, limites de altura, legenda, eixos e barra de ferramentas são preservados.
O clique transporta o `bbox` do primeiro ponto ao atributo de evento, executa
a ação configurada e limpa esse atributo. A implementação controla ações
pendentes e libera o gráfico ao sair da página.

A aceitação compara séries, título, escala, tamanho e clique antes/depois de
uma alteração. O frontend passou 160 testes e o fluxo Chromium passou dez
etapas sem acesso ao MPR. O pacote completo adiciona cerca de 1,33 MB gzip
quando solicitado. Playground/editor interno, efeitos de inicialização do editor
sobre dados de exemplo e certificação de todos os tipos de traço ficam fora
deste contrato. As opções dos demais widgets de gráfico mantêm seu escopo anterior.

A VM Windows aprovou os dois builds e os dois runtimes, original e reconstruído,
com resultados idênticos ao Ruby e hashes de entrada preservados.
[Evidências](../evidence/custom-plotly-2026-10-07.json).


## Ações de armazenamento no navegador

Três ações do Feedback Module recebem adaptadores TypeScript quando o hash da
fonte original é reconhecido: leitura de valor, leitura de `ShowEmail` e gravação
de `ImageB64`. O registro preserva os nomes dos parâmetros do modelo, incluindo
maiúsculas e minúsculas. JSON inválido, valores ausentes e falhas de armazenamento
mantêm o comportamento das implementações verificadas.

As 33 comparações com o JavaScript original passaram. O Chromium Ruby executou
dez passos sem MPR, incluindo persistência após nova navegação. A VM certificou
os projetos original e reconstruído com os mesmos resultados. Fontes alteradas,
AsyncStorage nativo e sincronização offline continuam fora desse contrato.
Veja a [evidência](../evidence/feedback-storage-2026-10-07.json).

## Adaptadores Java com fonte verificada

A exportação reconhece duas implementações do Feedback Module pelo SHA-256 do
Java: `ValidateEmail` e `XSS_Sanitizer`. Somente as versões verificadas geram
registros explícitos em `config/adapters.rb`; fontes ausentes ou alteradas
continuam exigindo um adaptador do projeto. O runtime executa Ruby e dispensa
o MPR e a JVM. Os registros são código Ruby editável.

Os testes comparam 32 entradas com o Java original, incluindo Unicode,
entradas vazias e nulas. A ação legada `XSS_Sanitizer` mantém seu comportamento
por expressões regulares; ela não substitui escape de HTML ou uma política de
sanitização da aplicação. Outras ações Java/JavaScript e integrações externas
continuam precisando de implementação e aceitação próprias.

## Captions estruturadas

Captions aceitam traduções, fallback, parâmetros por atributo ou expressão,
formatação numérica/data e referências a objetos da página, snippet ou widget.
As declarações Ruby preservam esses metadados no round-trip. O frontend aplica
a localidade selecionada e mantém a precisão do transporte Decimal, inclusive
acima do limite exato de Number. Atualizar a série não substitui seu contexto.

O cenário chart-captions compara nomes e valores antes/depois de uma alteração
no runtime nativo. Padrões de data não reconhecidos são rejeitados explicitamente.
Opções visuais avançadas de Plotly permanecem uma frente separada.

## Precisão Decimal

Ruby usa `BigDecimal` e o frontend usa `decimal.js`. Literais, soma, subtração,
multiplicação, resto, comparação e divisão evitam conversões intermediárias para
`Float`/`Number`. Divisão usa 38 dígitos significativos, conforme o runtime 11.12.1
instalado; `round` respeita `HalfUp`/`HalfEven`, e o export preserva `DecimalScale`.
`floor`, `ceil`, `abs` e `parseDecimal` sem formato também usam valores exatos.

A API interna transporta Decimal como `{"__mxrb_decimal":"9007199254740993.12345678"}`.
Use os helpers de `bridge/decimal` em extensões TypeScript. O contrato inclui
campos editáveis, parâmetros de página, filtros, ordenação, rascunhos e nanoflows.
Coordenadas de gráficos passam para ponto flutuante somente na apresentação.

SQLite grava Decimal em `TEXT` canônico, aplica escala e arredondamento do projeto
no commit e rejeita valores fora do limite nativo. Colunas `REAL` existentes são
migradas preservando as linhas; dígitos já perdidos em gravações antigas não podem
ser recuperados. SQL externo sobre essas colunas precisa de comparação decimal,
pois a ordenação textual do SQLite não é numérica. Clientes da API devem adotar o
tag Decimal junto com o frontend regenerado. Parsing e formatação localizados
com padrões Java continuam fora deste contrato.

[Evidência de Decimal](../evidence/decimal-runtime-2026-10-06.json).

## Expressões de calendário

O avaliador Ruby e o frontend TypeScript executam `dateTime[UTC]`,
`add`/`subtract` de milissegundos até anos (incluindo semanas e trimestres),
`trimToSeconds/Minutes/Hours/Days/Months/Years` e conversão de epoch em
milissegundos. Operações de calendário têm variantes UTC; o backend usa o fuso
IANA do contexto de segurança e o navegador usa seu fuso local ou `timeZone`
explícito no avaliador. Uma chamada seguinte não herda o fuso do usuário anterior.

Meses e anos ajustam o dia ao último dia válido do destino. Horas e unidades
menores são durações; dias e semanas preservam o horário local através de DST.
Testes cobrem transições de Nova York, o salto de meia hora de Lord Howe e o dia
omitido em Apia. Esses testes locais não substituem a certificação do runtime
Mendix. A matriz nativa acrescenta 16 casos UTC na origem e no round-trip.

Veja os contratos oficiais de [adição de datas](https://docs.mendix.com/refguide/add-date-function-calls/),
[criação](https://docs.mendix.com/refguide/date-creation/) e
[início de períodos](https://docs.mendix.com/refguide/trim-to-date/).
Parsing/formatação localizada e diferenças entre datas continuam em contratos separados.


[Calendar evidence](../evidence/calendar-expressions-2026-10-06.json).

## Empilhamento e ações nos pontos — 6 de outubro de 2026

Gráficos de barras e colunas aceitam `barmode: "stack"`, com bases acumuladas
por categoria na ordem das séries, inclusive valores negativos e zero. A escala
inclui as bases e os totais. Ações `staticOnClickAction` e `dynamicOnClickAction`
executam pelo mesmo runtime de eventos usado pelas páginas, com o registro do
ponto, confirmação e bloqueio durante execução. Os pontos aceitam clique, Enter
e Espaço; a tabela acessível também permite executar a ação.

Em séries agregadas, a seleção segue o índice do ponto na lista ordenada de
origem, como no pacote Mendix Charts certificado. Não equivale necessariamente
ao primeiro registro da categoria agregada. Atualizar um ponto preserva o
contexto e os campos da página. O cenário `chart-interactions` verifica barras,
colunas, clique em agregados, valores negativos e criação de uma nova série.

A agregação de barras horizontais permanece não suportada: o pacote Charts agrupa pelo eixo numérico e pode concatenar rótulos. O runtime Ruby informa essa limitação explicitamente. A certificação horizontal usa pontos sem agregação, inclusive categorias repetidas.

## Séries dinâmicas de gráficos — 6 de outubro de 2026

Gráficos de linhas e colunas aceitam séries dinâmicas agrupadas pelo atributo
configurado, com ordenação da fonte e agregação independente por grupo. Alterar
os dados recalcula os pontos e inclui novos grupos. Nomes de série podem usar
`caption("Região {1}", parameters: ["$currentObject/App.Point.Region"])` nas
propriedades Ruby tipadas; o frontend resolve o parâmetro no registro da série.
Valores numéricos e strings de mesmo conteúdo permanecem grupos distintos.

Os testes cobrem parâmetros simples de expressão ou atributo. Traduções,
formatação personalizada e referências a outras variáveis de página ainda não
estão certificadas nessa projeção de captions. Empilhamento, ações em pontos e
opções avançadas de Plotly permanecem fora deste incremento. O workflow Windows
executa o novo cenário `chart-series` no original e no modelo reconstruído.

## Atualização de 5 de outubro de 2026

O catálogo do runtime descobre novos modelos, DTOs, páginas, enums e serviços
nos arquivos Ruby carregados, sem exigir edição manual do manifesto. Aplicações
com `runtime_model: ruby` executam sem abrir MPR; projetos legados precisam ser
exportados novamente para adotar esse contrato. Remoção e renomeação de entradas
legadas ainda precisam de reconciliação explícita.

A UI avalia papéis de módulo e expressões de visibilidade/editabilidade,
combinando-os com a política herdada do Data View. Papéis desconhecidos não
liberam acesso. Isso complementa a autorização do servidor. XPath inclui funções
de strings e datas, palavras de período e fuso horário da sessão; limites de
mês/ano usam calendário, com testes de DST. A cobertura não representa paridade
universal entre bancos e todas as funções nativas.

Callbacks persistentes e transitórios alcançam subtipos. Regras de validação
herdadas agora verificam obrigatoriedade, unicidade entre tabelas de subtipos,
igualdade, intervalos inclusivos e comprimento UTF-16 antes do commit com eventos.
Falhas revertem a transação e retornam feedback estruturado HTTP 422. Expressões
regulares JVM exigem um adapter `regular_expression` explícito; a sintaxe não é
reinterpretada silenciosamente como Ruby Regexp. Regras desconhecidas falham
explicitamente. Uma matriz de 21 casos concordou com o Runtime nativo: veja a
[evidência de paridade](../evidence/validation-parity-2026-10-05.json). A sintaxe
de igualdade usa `Value` no armazenamento nativo; datas sem horário foram
certificadas. No 11.12.1, um limite de data com horário aceito pelo MxBuild
falhou ao iniciar o Runtime e permanece fora dessa certificação.

VetClinic editado em Ruby passou criação pelo serviço alterado, nova coluna,
projeção de página, persistência após reabrir, rollback e exclusão com MPR
proibido ([evidência](../evidence/vetclinic-ruby-2026-10-05.json)). Isso também
cobre callbacks nativos que compartilham a transação da API.

A [certificação Windows](windows-studio-pro.md) passou seis builds nativos locais
e CRUD no runtime oficial. VetClinic passou renderização e CRUD pela API nativa.
O [relatório](../evidence/native-2026-10-05.json) separa essas provas de equivalência
visual, formulários, widgets externos, Java/JS customizado e layouts móveis ainda
sem uma matriz completa. O workflow semanal adiciona build e runtime headless.

## Direção principal: Mendix → Ruby + React/TypeScript

O objetivo da conversão é uma aplicação com backend e regras em Ruby e frontend
web editável em React/TypeScript, sem executar o runtime Mendix. Retornar ao MPR
é um contrato adicional, não o critério de autonomia da aplicação Ruby.
`runtime_only` não significa fonte opaco: código Ruby e rotas React próprios
podem ser integralmente editáveis mesmo sem projeção de volta ao Studio Pro.
Por isso, `portability --require-native` verifica a direção Ruby → Mendix;
ele **não** certifica a conclusão de Mendix → Ruby.

Novas exportações declaram `runtime_model: ruby`: o modelo de execução, esquema
de persistência, segurança e grafos vêm das definições Ruby carregadas. Não se
abre nem se gera um MPR para executá-los. O manifesto e metadados de identidade
continuam presentes; não são interpretados como código de negócio. MPR e
sidecar de reconstrução são preservados para round-trip, não como fallback de
execução. Aplicações antigas sem essa configuração mantêm o bridge legado;
faça nova exportação para obter o contrato novo.

Schemas de widgets pluggable são exportados separadamente em
`.mxrb/widget_schemas`, mantendo a revisão exata de cada widget por página,
layout ou snippet. Eles validam as propriedades Ruby sem abrir o MPR; não
contêm os valores de negócio dos widgets. Uma exportação nova exige esses
schemas e falha explicitamente se estiverem ausentes.

Widgets incomuns de layouts podem aparecer como `form_widget(Mxrb::Forms...)`:
suas propriedades continuam editáveis em construtores tipados, sem hashes ou
referências a fragmentos opacos. Essa representação não acrescenta um renderer
web para tipos ainda não suportados.

Isso não traduz automaticamente grafos sem declaração Ruby nem implementações
Java externas: exigem implementação Ruby/adapter explícito. Preservação desses
artefatos não conta como funcionalidade concluída.

### Dez widgets de apresentação e execução sem MPR

`menu_bar` e `navigation_tree` usam menus recursivos de `app/presentation`, com
ações de página/microflow/nanoflow, parâmetros, traduções de legenda, ícones e
filtragem pelas permissões. Referências mantêm o módulo de origem do menu;
ações negadas são removidas mesmo quando seus filhos continuam autorizados. `navigation_list`
preserva conteúdo e ações de seus itens. `snippet` expande widgets reutilizáveis
com parâmetros nomeados de objetos/escalares, mapeamentos e proteção contra
recursão. DataViews podem editar objetos diferentes no mesmo snippet sem trocar
o objeto da página. Parâmetros ausentes são reportados.
`static_image` aponta para arquivos exportados em `frontend/public/assets/images`.
`scroll_container` preserva as cinco regiões, dimensões em pixels/percentual,
layouts headline/sidebar e os modos de abertura/fechamento, sobreposição e
deslocamento. Layouts compartilhados também são declarações Ruby em
`app/presentation`: seus placeholders recebem argumentos nomeados e layouts
aninhados são compostos a cada leitura da página, com detecção de ciclos.

`reference_set_selector`, incluindo a forma nativa InputReferenceSetSelector,
grava coleções de referências e respeita bloqueios herdados. Referências aos
objetos-alvo e leitura das associações são autorizadas no backend. Caminhos
compostos resolvem um único objeto proprietário antes de gravar; caminhos
ambíguos/vazios não viram consultas sem escopo. O servidor avalia XPath antes da
paginação: comparações, booleanos, aritmética, funções de strings, referências
a variáveis, caminhos de associações diretas/inversas e predicados aninhados.
Por exemplo, `[App.Item_Tags/App.Tag[Name = 'Visible']]` filtra pelo objeto
relacionado. Caminhos vazios não correspondem a objetos e comparações de conjuntos
são existenciais. O mesmo avaliador atende retrieves de microflows.
Cada objeto e membro acessado pela consulta HTTP passa por autorização; campos
privados não podem ser usados para inferir resultados. O contexto de
`$currentObject` é recuperado do banco e autorizado. Referências previamente
selecionadas fora do filtro são preservadas. Sintaxe inválida é rejeitada, com
limites de tamanho e profundidade. Isso não implementa todos os eixos, tokens e
funções do XPath nativo.

`file_manager`, `image_uploader` e `image_viewer` usam `/api/files/:entity/:id`.
O backend exige autorização sobre o objeto e seu membro `Contents`; mutações
por cookie também exigem CSRF. Conteúdo binário fica no banco SQLite, com teto
de 20 MiB por arquivo. Nome e MIME fornecidos pelo cliente não controlam caminhos
de disco nem conteúdo executável: somente assinaturas raster reconhecidas são
exibidas inline; os demais arquivos são anexos, com `nosniff` e CSP restritiva.
Limites/extensões próprios do widget são verificações adicionais da UI, não uma
política de segurança do servidor. O modelo Ruby pode declarar
`file_policy max_bytes: 1048576, extensions: %w[png], images_only: true`, aplicada
também contra uploads que ignoram a UI. `Name`, `FileSize` e `HasContents` são
atualizados também quando herdados de `System.FileDocument`. `generalizes`
resolve atributos da cadeia de entidades nas tabelas, nos objetos Ruby e no
schema enviado ao frontend. Consultas pela entidade base encontram seus subtipos,
inclusive associações com destino em `System.FileDocument` ou `System.Image`.
Uploads para subtipos de `System.Image` exigem assinatura raster. CRUD e arquivos
verificam as permissões do tipo concreto: consultar pela base não concede acesso
adicional. As regras de acesso continuam próprias de cada entidade, conforme o
[contrato de segurança do Mendix](https://docs.mendix.com/refguide/access-rules/).
Um trigger transacional remove blobs na exclusão pelo runtime, inclusive com
eventos desativados; rollback SQL e restauração de snapshots do interpretador
restauram registro, conteúdo e miniaturas. Downloads usam cookie de mesma origem.
Imagens usam fontes de contexto, associação, microflow e nanoflow; dimensões
percentuais/automáticas, fallback e abertura da imagem são cobertos.

`show_as_thumbnail` solicita uma miniatura PNG real pelo mesmo endpoint, com
`thumbnail_width` e `thumbnail_height` entre 1 e 1024. A imagem mantém proporção,
não é ampliada e tem orientação corrigida e metadados removidos. GIF/WebP animado
usa o primeiro quadro. O cache no SQLite é invalidado por substituição/exclusão
do arquivo e respeita as mesmas permissões do download original.
O processamento requer ImageMagick 7 (`magick` no PATH), ou ImageMagick 6 com
`MXRB_IMAGEMAGICK=convert`. A ausência do worker ou imagem inválida gera erro
explícito. A execução usa argumentos separados, decodificador raster explícito,
limites de memória/tempo e encerramento após 15 segundos, seguindo as opções de
[recursos do ImageMagick](https://imagemagick.org/security-policy/). A CI instala
e executa esse worker; downloads originais não precisam dele.

O fixture `spec/fixtures/ruby_presentation_widgets/project.rb` testa os dez tipos,
recursos exportados, edição pública e persistência. O cenário
`spec/fixtures/frontend_browser/ruby_presentation_widgets_flow.json` verifica
33 passos no Chromium, inclusive seleção filtrada por associação aninhada,
persistência após recarregar, solicitação de thumbnail, navegação e abertura
de região lateral com largura de 240 px,
com MPR e sidecar removidos da aplicação de teste. Upload é coberto por testes de
componente e API. `ruby_standalone_runtime_spec.rb` proíbe abrir projetos MPR e
verifica alteração de fluxos, chamada interna a Ruby personalizado e reabertura
do banco; custom actions têm teste próprio de resolução sem MPR.

Os contratos de XPath por associação, persistência polimórfica de arquivos e
miniaturas reais têm gates em `spec/runtime/xpath_spec.rb` e
`spec/ruby_runtime_compatibility_spec.rb`, incluindo reinício, permissões,
cache, rollback, HTTP e runtime proibido de abrir MPR.
O Sudoku usado na CI também inicializa 9 módulos, 19 páginas e 4 entidades
persistentes sem MPR. Senhas de demonstração ocultadas na exportação não são
necessárias para construir o modelo de autorização; credenciais do runtime
continuam sendo configuradas no `SessionManager` pelo ambiente da aplicação.

Limites ainda abertos: funções/eixos/tokens restantes do XPath completo,
equivalência de todos os eventos/validações herdados do runtime Mendix,
ações cliente além do recorte abaixo, parâmetros tipados/variáveis locais mais
avançadas e integrações particulares. Layouts móveis/nativos, comportamento
responsivo exato de cada tema e equivalência visual com Studio Pro não estão
certificados. Os limites novos têm testes em `ruby_advanced_presentation_spec.rb`
e nos componentes React; isso não elimina os gates pendentes em projetos reais.
Esse gate certifica o fixture e os contratos descritos, não conversão universal.

### Ações cliente e layout responsivo

`save_changes`, `cancel_changes`, `delete` e `close_page` executam ações cliente
sem procurar microflows com esses nomes. A opção `close_page: true/false` de
salvar/cancelar/excluir é preservada na leitura, no Ruby editável e na reconstrução
Mendix. Efeitos `close_page` de microflows e nanoflows também são aplicados.
Voltar/Avançar restaura a página e seu objeto, atualizado pelo backend; fechar
na primeira página não sai da aplicação.

Páginas com Salvar/Cancelar, inclusive em snippets compartilhados, mantêm
rascunhos dos membros editados. Salvar inclui o texto ainda em foco e envia os
objetos persistentes em uma transação (`POST /api/records/commit`, até 1.000
objetos): erro ou falta de permissão desfaz o lote inteiro. Cancelar restaura a
última versão confirmada. Falhas de gravação preservam o rascunho para nova
tentativa; edições feitas durante uma gravação permanecem pendentes. DTOs
continuam locais. Páginas sem essas ações mantêm a gravação imediata existente.
Uploads e efeitos já persistidos por microflows não pertencem a essa transação
de edição. Excluir usa o objeto de contexto; exclusão múltipla, seleção de
`SourceVariable`, confirmações nativas e os demais tipos de ação continuam
pendentes. Popups são apresentados pela navegação de páginas, sem uma pilha
visual de janelas modais.

LayoutGrid aplica pesos de 1–12, `grow` e `auto` por desktop, tablet (até 991 px)
e celular (até 767 px), quebra de linha e alinhamentos de linha/coluna. Isso
certifica o grid web declarado; não equivale a aplicativos móveis nativos nem
a todos os breakpoints e estilos de temas particulares.

O fixture de apresentação existente verifica 54 passos no Chromium, incluindo
cancelamento, confirmação, persistência após recarga e retorno à página anterior.
Dois cenários adicionais verificam o mesmo grid em 800 px e 390 px. Os três
rodam com acesso ao MPR proibido. Testes React cobrem texto em foco, falha/retry,
múltiplos objetos e histórico do navegador.

### Campos e Data Views editáveis

A exportação expõe no Ruby da página a editabilidade do campo, condição,
estilo somente leitura, placeholder, senha, limite de tamanho, rótulo acessível,
obrigatoriedade ARIA, tabulação e autocomplete. Alterar essas opções em
`app/pages/**/*.rb` muda a projeção servida pelo backend Ruby; não exige
recompilar um MPR. A apresentação React aplica as opções suportadas.

Data Views propagam o bloqueio de edição aos campos, inclusive em views
aninhadas. Condições booleanas de expressão são avaliadas com tipos, parênteses,
precedência e strings literais, sem `eval`. Condições desconhecidas ou ainda
opacas não liberam edição. Papéis de módulo são combinados com as expressões;
variantes nativas adicionais precisam de seus próprios contratos.
As regras de autorização do backend continuam independentes desse controle UI.

Eventos de foco, alteração e saída recebem o objeto atualizado; alteração e
saída aguardam a gravação. Respostas da API não remontam o campo nem removem
seu foco. Objetos vindos do servidor permanecem persistentes; falhas de gravação,
inclusive 404, são exibidas em vez de simular sucesso local.

`listen_to` acompanha a seleção da grade nomeada na página, sem confundir a
seleção de outra grade. Fontes por associação percorrem cada etapa usando o
objeto anterior e param em ligações vazias, sem consultar toda a entidade.

O fixture `spec/fixtures/ruby_frontend_editability/project.rb` e o cenário
`spec/fixtures/frontend_browser/ruby_editability_flow.json` verificam edição
condicional, seleção e persistência após recarregar, usando somente Ruby e
React. Testes de componente cobrem escrita rejeitada, foco, eventos, condições
e associações com múltiplas etapas. Isso fecha esse recorte, não toda a matriz
de frontend nem todas as dependências do baseline.

### Seleção por rádio, títulos e abas

`radio_button_group` oferece seleção booleana ou por enumeração, legendas,
orientação horizontal/vertical, navegação nativa por teclado, persistência e
eventos de foco/saída do grupo. Respeita os bloqueios herdados de Data Views;
opções desconhecidas são sinalizadas, sem substituir o valor armazenado.
Valores de enumeração curtos e qualificados são reconhecidos. A gravação
preserva a representação recebida, e comparações com literais de enumeração
em condições reconhecem ambas sem confundir tipos qualificados diferentes.

O schema servido usa os valores e traduções Ruby das enumerações exportadas,
com fallback ao manifesto para definições legadas sem implementação carregada.
Alterar `app/enumerations/**/*.rb` não exige recompilar o MPR; recarregue a
aplicação para obter o schema atualizado. Aplicações `runtime_model: ruby`
descobrem novas declarações carregadas e reconciliam remoções e renomeações;
entradas legadas precisam de nova exportação. O manifesto permanece como
metadado privado de reconstrução, sem exigir cadastro manual do runtime.

`page_title` usa o título da página Ruby carregada. `tab_control` seleciona um
painel por vez, suporta setas/Home/End e mantém os campos dos painéis já abertos
montados, preservando rascunhos. Painéis ainda não abertos são carregados sob
demanda. O fixture `spec/fixtures/ruby_frontend_core_widgets/project.rb` e o
cenário `spec/fixtures/frontend_browser/ruby_core_widgets_flow.json` verificam
esse comportamento, condições por enumeração e persistência após recarregar.
Variantes nativas de abas ainda não projetadas não estão cobertas por esse contrato.

## O que o MXRB garante

O modo Ruby possui três classes explícitas de portabilidade:

- `native`: a declaração Ruby é materializada como documento editável no MPR;
- `preserved_native`: o documento Mendix original permanece no sidecar reversível;
- `runtime_only`: o código funciona no runtime Ruby/TypeScript do MXRB, mas não
  se torna sozinho uma página ou fluxo nativo do Studio Pro.

Audite um projeto antes de entregá-lo:

```bash
bundle exec mxrb portability .
bundle exec mxrb portability . --json
bundle exec mxrb portability . --require-native
```

`--require-native` termina com código diferente de zero quando existe código que
depende do runtime MXRB. Isso impede usar “round-trip sem perda” como sinônimo
incorreto de “todo o código virou documento Mendix”.

Entidades, atributos e validações `required`/`unique` declarados em Ruby voltam
ao domínio Mendix. O contrato inclui documentação, valor padrão, tamanho de
string, localização de data, referência de enumeração e associações locais ou
cross-module. Associações incluem tipo, owner, storage format, documentação,
delete behavior e identidade nativa estável. Microflows e nanoflows
com grafo coberto pelo DSL são exportados automaticamente com bloco `native` e
`body_fingerprint`; ao editar o corpo Ruby, a recompilação atualiza o documento
Mendix. Grafos ainda não mapeados ficam intactos no sidecar e aparecem como
`runtime_only`.

Novas páginas que precisam existir no Studio Pro devem usar `Page.native`. Uma
rota React manual continua sendo uma rota React — o relatório não a promove
artificialmente a página Mendix.

A matriz por superfície, com a diferença entre leitura, preservação e edição,
está em [Cobertura Ruby nativa](cobertura-ruby-nativa.md).

## TypeScript que roda dentro do Mendix

Para um componente React/TypeScript tornar-se um artefato Mendix, desenvolva-o
como pluggable widget oficial:

```bash
mkdir -p widgets-src
bundle exec mxrb widgets new OrderSummary widgets-src
cd widgets-src/OrderSummary
npm start

cd "$PROJECT_ROOT"
bundle exec mxrb widgets build widgets-src/OrderSummary \
  --project "$PROJECT_ROOT"
bundle exec mxrb widgets sync project.rb build/App.mpr
```

O comando `new` chama o gerador oficial fixado
`@mendix/generator-widget@11.11.0`. `build` executa `npm ci` e `npm run release`;
o resultado é um `.mpk`, o formato oficial descoberto pelo Studio Pro na pasta
`widgets`. O `widgets sync` existente lê o schema do MPK e sincroniza as
propriedades no MPR.

O MXRB falha antes de escrever quando a DSL concisa tenta levar toolbar ou
`on_change` do fallback de Data Grid 2 ao schema oficial: essas formas não são
estruturalmente equivalentes. Use botões core explícitos para chamar microflows
ou nanoflows, ou implemente a interação no próprio pluggable widget.

Referências oficiais:

- <https://docs.mendix.com/apidocs-mxsdk/apidocs/pluggable-widgets/>
- <https://www.npmjs.com/package/@mendix/generator-widget>

## Sessão segura no frontend React

O scaffold não grava bearer token no `localStorage`. Login cria cookie de
sessão `HttpOnly; SameSite=Strict`; requisições de mesma origem usam
`credentials: same-origin`, e mutações autenticadas por cookie exigem
`X-CSRF-Token`. Configure `MXRB_SECURE_COOKIES=true` quando a aplicação for
servida por HTTPS. Bearer tokens estáticos continuam disponíveis para clientes
de integração que não são navegador.

## Editor e LSP

Projetos novos e exportados incluem `.ruby-version` e `ruby-lsp` no grupo de
desenvolvimento. Depois de `bundle install`, o LazyVim detecta Ruby LSP; o
frontend usa o TypeScript language server fornecido pelo projeto.

```bash
bundle install
npm ci --prefix frontend
nvim .
```

Atalhos LazyVim mais úteis: `gd` vai à definição, `gr` mostra referências,
`K` mostra documentação, `<leader>ca` abre code actions, `<leader>cr` renomeia,
`<leader>cf` formata e `<leader>xx` abre diagnósticos.
