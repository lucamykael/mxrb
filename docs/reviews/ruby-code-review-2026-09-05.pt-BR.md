# Revisão Ruby e round-trip — 5 de setembro de 2026

Esta revisão cobre as fronteiras tipadas de Forms, widgets pluggable e settings,
além dos caminhos de geração de fonte pública. O resultado não certifica todos
os recursos Mendix nem substitui a abertura e validação no Studio Pro. Os
exemplos são sintéticos; nenhum nome ou conteúdo de projeto privado foi incluído.

## Checkpoint final local — 8 de setembro de 2026

Após a integração dos eventos runtime, das propriedades pluggable tipadas, da
atomicidade de páginas e das guardas do writer, a suíte completa executou
**1.782 exemplos, zero falhas**, seed 5910, sem coleta de cobertura. Duas
conversões frescas para 11.12.1 mantiveram **2.261** e **2.486** unidades e
passaram pela integridade estrutural. O gate dos widgets pluggable confirmou
igualdade estrutural e byte a byte dos **1.060 schemas** embutidos.

A comparação dos grafos de identidade com a entrega anteriormente validada no
Windows não encontrou falhas: o primeiro caso teve 2.073 unidades exatamente
iguais e 188 diferenças somente de identidade; o segundo, 2.225 e 261. Foram
reconciliados 96.466 e 52.880 IDs, respectivamente, sem remapeamento semântico.
O MxBuild local preservou os diagnósticos de referência: zero problemas de
modelo e a mesma falha Java preexistente no primeiro caso; exatamente os mesmos
689 problemas e a mesma falha de deploy no segundo. Nenhuma assinatura nova
foi introduzida.

A nova fonte pública contém **545 literais Hash** e os mesmos **36 UUIDs** das
18 ACLs ambíguas já documentadas. Os cinco sinais de `storage_schema` continuam
falsos positivos conhecidos. Esses totais são sinais conservadores, não uma
medida percentual de cobertura.

Um lote independente para revalidação no Windows foi preparado como
`mxrb-validation-20260908-runtime-v1`, com MPRs e sidecars frescos; o lote de
5 de setembro permaneceu intocado. A VM voltou a responder na rede, mas o
servidor RDP não concluiu a ativação do desktop, inclusive em sessão
administrativa e sem aceleração gráfica. Portanto, este checkpoint registra os
gates locais completos e **não declara uma nova validação visual no Studio
Pro**. A validação Windows permanece pendente até a recuperação da sessão RDP.

## Adendo atual — identidade de domínio e autoria tipada de fluxos

A validação local deste lote executou **1.737 exemplos, zero falhas**, seed
3751, sem coleta de cobertura. Duas conversões frescas para 11.12.1 mantiveram
as contagens de unidades e passaram pela integridade estrutural. Os **1.060
schemas** embutidos continuam estruturalmente iguais e byte a byte idênticos.
A nova checagem Windows deste lote concluiu os dois builds com Studio/MxBuild
11.12.1 assinados. O primeiro caso manteve zero diagnósticos de modelo; o
segundo manteve exatamente os 689 diagnósticos originais, incluindo os dois
erros `CE0161` e `CE0571`. Os erros de build também foram preservados; no erro
Java do primeiro caso, a única diferença foi o prefixo do diretório de trabalho.
Ambos continuam sem pacote implantável: equivalência de diagnóstico não é
build bem-sucedido. A inspeção visual abriu ambas as cópias sem conversão e
alcançou o estado Ready, com zero e dois erros respectivamente. O segundo caso
mostrou 225 deprecações e 478 avisos na interface, que não são intercambiáveis
com os 462 avisos registrados pelo MxBuild.

O transporte foi conferido por nomes, conjuntos completos e SHA256: 4.749
arquivos auxiliares em cada uma das duas localizações, além dos dois MPRs.
Todos os 9.498 checks de arquivos auxiliares passaram. Os resultados nativos
das seções seguintes pertencem às saídas anteriores.

| Fonte pública `app/` dos dois casos | Antes deste lote | Atual |
| --- | ---: | ---: |
| Ocorrências de UUID | 6.356 | 36 |
| Literais Hash | 2.901 | 743 |
| UUID em páginas | 20 | 0 |
| Literais Hash em serviços | 1.457 | 0 |

As categorias não contam defeitos distintos nem medem cobertura do metamodelo.
Os 743 hashes restantes estão nas páginas; fingerprints e declarações públicas
de identidade de unidade continuam ausentes no recorte auditado. Cinco sinais
de schema em textos/expressões continuam sendo falsos positivos conhecidos.

As principais alterações verificadas são:

- `RecordIdentity` recupera apenas identidades de associações, ACLs e membros,
  índices e membros, validações e traduções, callbacks, generalização e OQL.
  Valores editados continuam autoritativos; não há pareamento pela posição.
  Renomeações e remoções explícitas desambiguam mudanças de chave. Uma remoção
  isolada, sem declarar a coleção completa, falha claramente: não conserva o
  alvo silenciosamente nem apaga outros membros por inferência.
- O carregamento valida novas declarações depois de todos os arquivos. Inserir
  uma classe antes de outra existente ou mover a classe existente para um
  arquivo posterior não toma sua identidade. Renomeações ambíguas continuam
  recusadas. O relatório de portabilidade utiliza o mesmo carregador, incluindo
  ambiente, identidades privadas, metadados de fluxos e fragmentos internos.
- Fontes DataView, fontes de configuração e colunas de grid usam chamadas
  tipadas quando sua representação é exatamente equivalente. Propriedades de
  design recuperam os IDs pelo manifesto. As **415 projeções de páginas** foram
  comparadas integralmente; `Page.configure` continua sendo projeção runtime,
  não uma promessa de edição nativa do MPR por essa API.
- Criação e alteração de objetos, argumentos e títulos de páginas, traduções
  de mensagens e validações, headers REST e decisões por regra usam blocos
  Ruby. As APIs anteriores continuam aceitas. Casos suportados preservam ordem,
  valores vazios e argumentos/headers repetidos. Blocos inválidos não instalam
  atividades parciais. `rule_decision` é testado também com um alvo nativo
  `Microflows$Rule`, além da edição e recompilação do fluxo chamador.
- O emissor não reinterpreta strings de expressão como números ou `nil` Ruby.
  Textos como `"09"`, `"001"` e `"1.00"` permanecem exatamente os mesmos na
  representação Mendix. Valores Forms copiam strings e coleções recebidas sem
  congelar nem manter referências mutáveis aos dados do chamador.
- `RubyApp::RegularExpression` oferece expressão, documentação, exclusão e
  nível de exportação tipados, com identidade privada e classificação nativa
  no relatório de portabilidade. Campos desconhecidos, ausência, `nil` e
  `false` são preservados. Expressões são texto Mendix/JVM, não `Regexp` Ruby.
  Colisões de família/módulo e renomeações ou remoções referenciadas são
  rejeitadas no preflight.

Os **36 IDs restantes** pertencem a 18 pares de ACLs ambíguas. Dois pares são
semanticamente idênticos; os demais diferem em permissões editáveis. Usar essas
permissões como identidade poderia trocar vínculos durante uma edição. O
fallback legado permanece até definir nomes Ruby estáveis com vínculo privado.

Também permanecem a integração completa das propriedades pluggable tipadas na
projeção pública,
formatos do metamodelo fora das rotas semânticas implementadas e ações/caminhos
de erro não implementados no runtime TypeScript de nanoflows. A preservação
nativa não certifica equivalência funcional desse runtime. Renomeação de
entidades e evolução arbitrária de schemas continuam fora do contrato seguro.
Não se declara independência dos sidecars, conclusão global do metamodelo ou
aprovação global de lint. A conversão inversa 11→9 permanece suspensa.

### Incremento runtime posterior ao lote nativo

Os eventos das páginas passaram a aceitar argumentos por blocos Ruby, com
preservação de ausência, valores vazios, `nil`, `false` e expressões textuais.
Misturas com a declaração legada e argumentos duplicados são rejeitados; os
valores são copiados para impedir mutações posteriores por referências externas.
As 415 projeções completas continuaram iguais, com `native_definition`
invariável. A emissão prevista reduz os hashes das páginas de 743 para 599;
os números da tabela acima pertencem às fontes efetivamente convertidas no
lote nativo, antes desse incremento. A suíte seguinte executou **1.760 exemplos,
zero falhas**, seed 33913, sem coleta de cobertura. Ela inclui a prova isolada
de propriedades pluggable, ainda sem certificar a integração dessa API na fonte
pública.

## Adendo — alterações posteriores ao resultado integrado

Esta seção e as seguintes registram resultados históricos anteriores ao adendo
atual. Seus limites e contagens devem ser lidos no contexto da respectiva etapa.

Os **1.587 exemplos**, gates, medições e contagens apresentados nas seções
seguintes são resultados históricos da rodada anterior. A validação atual,
após as alterações deste adendo, executou **1.613 exemplos, zero falhas**,
seed 26058, sem coleta de cobertura. Os **1.060 schemas** das duas conversões
atuais preservaram exatamente os bytes; as conversões mantiveram as contagens
de unidades e passaram pela integridade estrutural. A validação nativa na VM
Windows, autorizada posteriormente, concluiu os cinco casos com Studio/MxBuild
11.12.1 assinados e JDK 21.0.5. O primeiro par manteve zero diagnósticos de
modelo e a mesma falha Java; o segundo manteve exatamente os 689 diagnósticos
originais por severidade, código, mensagem e localização semântica. Nenhuma
assinatura nova foi introduzida. O caso dos 41 widgets core Forms apresentou
somente as cinco referências ausentes intencionais (`CE1613`). Isso comprova
ausência de regressões nesses casos, não implantação bem-sucedida dos projetos
originais. Não houve alteração de branch nem aprovação global de lint.

A primeira abertura no Studio 11.12.1 concluiu a checagem com zero erros,
86 deprecações e 271 avisos; o MPR manteve seu SHA256 ao abrir e fechar. Esses
avisos visuais não foram comparados com uma abertura do original. A segunda
abertura também concluiu a checagem, mantendo os dois erros `CE0571` e
`CE0161` já presentes no original segundo o MxBuild. A interface apresentou
225 deprecações e 478 avisos; a lista visual de avisos não é intercambiável com
a saída MxBuild. O MPR permaneceu inalterado na inspeção. O recorte verificado
é carga, consistência e fidelidade de conversão, não execução funcional completa
das aplicações nem eliminação dos defeitos originais.

A fonte gerada passou a omitir IDs técnicos das declarações `mendix_name`
abrangidas por `SourceIdentity`. O manifesto resolve as identidades durante o
carregamento; o snapshot privado `.mxrb/source-identities.json` registra os IDs
materializados, caminhos e classes para a reexportação das fontes embutidas.
Foram acrescentadas declarações tipadas de índices e validações, além da
migração sintática de fontes legadas com `Ripper`. A suíte atual cobre esses
contratos, além dos gates estruturais descritos acima.

A etapa seguinte também retirou os IDs dos valores de enumeração da fonte
gerada. O pareamento usa identidades privadas, sem inferir identidade pela
posição: `renamed_from:` expressa a renomeação e `remove_value` permite
desambiguar remoção com inserção. A política de senhas ganhou um bloco tipado
que distingue propriedade ausente de `false`; extensões desconhecidas e
valores explicitamente nulos mantêm a representação legada.

`Project#migration_losses(version)` passou a oferecer uma auditoria somente
leitura das propriedades e partes de settings removidas pela estratégia exata
9.6.1.29396. Os diagnósticos não incluem valores literais; qualquer remoção
detectada bloqueia a transição para esse destino antes da regravação do MPR.
Mesmo `nil`, `false` e valores vazios são relatados, sem presumir equivalência.
Um relatório vazio **não certifica compatibilidade**: coerções, mudanças de
tipos e outras diferenças do metamodelo ficam fora desse recorte. A auditoria
não aceita outros destinos e não libera a rota de conversão 11→9, que continua
bloqueada e suspensa nesta entrega por solicitação do usuário.

A identidade privada também passou a abranger papéis de módulo, papéis de
projeto e usuários de demonstração, com renomeação e remoção explícitas. O
pareamento herda apenas identidades, nunca permissões ou senhas. A declaração
`project_security` dispensa o ID público. Agendamentos conhecidos de minuto,
hora, dia e semana usam builders tipados; trocar o tipo não mantém propriedades
incompatíveis do tipo anterior. Referências recém-materializadas recebem o
marcador nativo correto, preservando marcadores existentes.

A auditoria atual ainda encontra 6.356 ocorrências de UUID e 2.901 literais
Hash nas fontes públicas dos dois casos. Fingerprints e declarações públicas
de identidade de unidade foram eliminados nesse recorte. Essas contagens
não representam defeitos distintos nem certificam cobertura do metamodelo.

Limites explícitos desta etapa:

- IDs de outros elementos filhos, como regras e membros de acesso, continuam
  presentes. Valores de enumeração e os membros de segurança descritos acima
  passaram a usar pareamento privado.
- Microflows e nanoflows homônimos já vinculados dependem da identidade privada
  e do tipo nativo. Chamadas somente pelo nome e novas declarações sem vínculo
  suficiente ainda podem ser ambíguas e são rejeitadas.
- Renomear uma entidade existente permanece bloqueado: exige uma operação
  semântica explícita, sem conversão automática em exclusão e recriação.
- Várias declarações no mesmo arquivo exigem correspondência inequívoca.
  Inserir uma classe nova antes de outra ainda não vinculada pode ser rejeitado;
  a ordem das declarações não tem garantia geral de independência.
- Regras de validação desconhecidas preservam o Hash legado `rule_info`;
  esta etapa não elimina todos os hashes nem todas as identidades públicas.

## Resultado integrado

A suíte completa final executou **1.587 exemplos, zero falhas**, seed 15430.
`git diff --check` passou. O gate oficial local carregou os 41 tipos core Forms;
as cinco referências ausentes nessa fixture são intencionais. O novo
`script/pluggable_schema_round_trip_gate` verificou igualdade estrutural e dos
bytes BSON de todos os 1.060 schemas embutidos nos dois projetos de referência.

Após as alterações finais da API Ruby, duas novas conversões pelo comando
`mxrb convert --studio 11.12.1` mantiveram suas 2.261 e 2.486 unidades. Os
diagnósticos MxBuild permaneceram iguais aos originais: um projeto passou pela
consistência do modelo e chegou à mesma falha Java preexistente; o outro manteve
exatamente os 689 diagnósticos originais. Nenhuma regressão nova foi encontrada
nesses gates. Não houve nova validação visual no Studio Pro nesta rodada.

Foram corrigidas também a ordem física dos campos de schemas, aliases legados,
contextos de atributos/associações, caminhos XPath e seleção de widgets.
Propriedades aninhadas que coincidem com métodos Ruby usam `set`/`append` com
blocos tipados. O campo legado `WidgetPhoneGapEnabled`, ainda sem representação
semântica, falha explicitamente em vez de ser descartado.

A fonte pública dos serviços agora recebe os metadados de comparação do
sidecar interno; não emite `body_fingerprint`. Os testes verificam fluxos
homônimos, corpo sem edição, edição autoritativa, isolamento entre projetos,
compatibilidade com declarações legadas e falha explícita quando faltam
metadados necessários.

| Auditoria de `app/` | Antes | Depois |
| --- | ---: | ---: |
| Ocorrências totais | 28.637 | 20.423 |
| Fingerprints públicos | 1.557 | 0 |
| Hashes literais | 8.667 | 3.048 |
| Operadores `=>` | 8.260 | 7.222 |
| UUIDs públicos | 10.146 | 10.146 |

As categorias se sobrepõem e não contam defeitos distintos. Cinco sinais de
schema são falsos positivos em textos/expressões. Os hashes restantes incluem
configurações semanticamente legíveis; ainda assim, a meta de autoria
inteiramente tipada e sem identidades técnicas públicas permanece aberta.

## Correções entregues nesta revisão

| Prioridade | Problema reproduzido | Correção e evidência |
| --- | --- | --- |
| P1 | Reordenar configurações `A, B` para `B, C`, renomeando `A`, fazia os dois itens receberem o ID original de `B`. | `lib/mxrb/settings/mpr_codec.rb` reserva os pareamentos por chave antes do fallback posicional e impede reutilizar um item consumido. Regressão em `spec/settings_dsl_spec.rb`. |
| P1 | Inserir uma configuração antes de itens existentes podia apropriar sua identidade; IDs derivados somente da posição também colidiam com baselines geradas pelo próprio codec. | A reserva considera toda a coleção; a identidade determinística de novos itens inclui sua chave semântica. Teste verifica preservação dos IDs anteriores, unicidade e determinismo. |
| P1 | `Settings::Node#set(:java_major_version, '21')` aceitava a propriedade mas gravava `java_major_version`, que não é o campo nativo `JavaMajorVersion`. | `set` e `fetch` agora resolvem o mesmo nome canônico. Regressão verifica o documento efetivamente codificado. |
| P2 | `Forms::Text` guardava strings do chamador; uma alteração posterior no texto original mudava a página. A coerção também congelava o array recebido. | `Translation` copia e congela suas strings; `Text` copia a coleção. Teste altera idioma, texto e array originais e verifica a estabilidade da página. |
| P2 | Cada construção pública de widget relia e reconstruía o catálogo JSON imutável. | `Forms::Catalog.for` compartilha um catálogo por versão com inicialização protegida por `Mutex`. A versão também é congelada; testes cobrem chamadas repetidas, threads e versão desconhecida. Cada widget continua sendo um objeto independente. |
| P2 | Settings aceitava valores escalares incompatíveis, coleções de componentes errados e alterações diretas no Hash `fields`. | `settings/value_contracts.rb` valida booleanos, inteiros, strings, assets binários, coleções e componentes conhecidos. `fields` retorna um snapshot congelado; a externalização de assets utiliza `set`. Testes negativos e round-trip binário do template oficial verificam a fronteira. |

Medição local ilustrativa, com Ruby 4.0.5 e 100 construções de `Forms.text_box`:
0,749 s antes e 0,000517 s depois do cache. É uma medição isolada da construção
de widgets, sem promessa de aceleração equivalente para exportações completas.
O cache é apropriado para schemas distribuídos com a biblioteca; alterações
nesses arquivos durante o processo exigem reinício ou construção explícita por
`Catalog.new`.

A validação direcionada dos codecs, modelos e emissores executou 57 exemplos
sem falhas. RuboCop passou nos sete arquivos Ruby dessa alteração. Esses números
se referem a este conjunto direcionado, não à suíte completa ou à cobertura
global. Esse conjunto também inclui a regressão da revisão paralela para
preservação de referências indiretas vazias (`spec/forms_entity_reference_spec.rb`).

A extensão de validação Settings passou RuboCop nos três arquivos dessa etapa
(`model.rb`, `value_contracts.rb` e `settings_value_contracts_spec.rb`). O arquivo
compartilhado `exporter.rb`, que recebeu uma troca de atribuição direta por
`set`, ainda apresentou `Metrics/BlockLength` no método `export!`, fora desse
trecho alterado. Não se afirma aprovação global do lint.

Nullability foi preservada onde há evidência: `OpenTelemetry` e `Tracing`
podem estar ausentes, assim como os callbacks legados de workflow e `Logs`/
`Traces`. O template oficial 11.12.1 entregue no repositório passa decode e
encode com baseline e produz os mesmos bytes BSON. Ausência de uma propriedade
continua distinta de atribuição explícita de `nil`.

Uma investigação posterior de dois erros Studio `CE3637` encontrou grids cuja
seleção `Single` virava `None`, apesar de os nomes `ListenTarget` e a posição dos
widgets irmãos estarem preservados. A correção paralela do campo físico
`Selection` restaura essa condição; não foi necessária mudança na identidade
dos widgets. `spec/forms_selection_listener_spec.rb` cobre a composição de um
grid selecionável e sua DataView após decode, fonte Ruby e encode. A fixture
fixa `Single` independentemente do encoder para detectar regressões reais.
Esse teste e os testes do codec pluggable executaram 13 exemplos sem falhas.
O gate MxBuild 11.12.1 posterior confirmou ausência de regressões de modelo nas
duas conversões reais: uma manteve exatamente os 689 diagnósticos originais;
a outra passou pela consistência de modelo e encontrou a mesma falha Java do
original. A comparação considera código, severidade, mensagem e localização
semântica. Isso certifica ausência de regressões nesses casos, não build limpo
dos projetos originais nem conclusão global de todos os recursos Mendix.

## APIs públicas finais de ACL e enumerações

Modelos persistentes e DTOs aceitam membros de ACL em blocos Ruby tipados:

```ruby
access_rule 'Sales.User', default_rights: :none do
  member 'Name', rights: :read_write, reference: 'Sales.Customer.Name'
  member 'Customer_Owner', rights: :read_only, kind: :association
end
```

O exportador RubyApp utiliza essa forma, sem Hashes explícitos de membros.
`members:` continua compatível; quando combinado com um bloco, seus membros
precedem os membros do bloco. Os aliases `:none`, `:read_only` e `:read_write`
convertem para os direitos nativos existentes. Um bloco inválido não instala
uma ACL parcial nem transforma uma declaração ausente em remoção de ACLs.
`spec/ruby_app_access_rule_dsl_spec.rb` verifica equivalência exata das ACLs
BSON, incluindo identidade, ordem e referências herdadas, e a persistência de
uma alteração de direitos sem mudanças adicionais.

As traduções de valores enumerados também usam declarações Ruby:

```ruby
value 'Ready' do
  translation 'pt_BR', 'Pronto'
  translation 'en_US', ''
end
```

As opções anteriores `caption:` e `captions:` continuam suportadas; misturá-las
com um bloco gera erro. Um bloco vazio representa ausência de traduções e não
introduz uma legenda automática. A ordem dos idiomas e textos vazios é
preservada. `spec/ruby_enumeration_translations_spec.rb` verifica exportação,
edição e recompilação mantendo as identidades nativas.

Essas APIs removem Hashes de membros e captions da fonte pública. Os IDs
existentes de regras, membros e valores enumerados continuam presentes na
exportação: são necessários para preservar o vínculo com a baseline. Os
exemplos acima mostram autoria de novas declarações; apagar IDs de uma fonte
exportada ainda não faz parte desse contrato. Esta entrega não significa
independência dos arquivos internos ou eliminação de todos os IDs públicos.

A revisão integrada também corrigiu colisões entre nomes de propriedades de
widgets e métodos Ruby. Valores aninhados chamados `source`, `schema`, `fetch`
ou `set` são emitidos por blocos explícitos `set(...)`/`append(...)`; o método
de contexto `source(:propriedade)` continua disponível.
`spec/pluggable_reserved_properties_spec.rb` cobre fontes de dados, objetos,
listas, ações Forms e widgets filhos. A revisão de schemas legados preserva
aliases físicos como `Name`, `Description` e `_Key`, além da ordem dos campos
da baseline, sem convertê-los silenciosamente para outra representação.

## Lacunas ainda abertas

| Prioridade | Local | Limite observado e próximo passo |
| --- | --- | --- |
| P1 para a meta de fonte inteiramente tipada | `lib/mxrb/exporter.rb`, `native_document_declaration` e fallback de `page_source` | Documentos sem declaração semântica ainda emitem `native_document`, IDs e `deep_structure`; páginas fora do caminho tipado podem emitir `form_structure`. Inventariar tipos concretos em fixtures, implementar seus modelos/DSLs e comprovar edição seguida de round-trip antes de retirar cada fallback. |
| P1 para independência do baseline | `lib/mxrb/exporter.rb`, `export_native_units` e bootstrap do projeto | O projeto exportado ainda carrega manifesto BSON em Base64 e fragmentos internos. Preservação do baseline é útil, mas não demonstra que cada propriedade está editável pela API Ruby tipada. Medir separadamente fidelidade de round-trip e ausência de estruturas opacas na fonte pública. |
| P2 | `lib/mxrb/settings/value_contracts.rb` | Tipos de valores e contenção conhecida agora são validados. Enumerações e faixas numéricas ainda precisam de metadados oficiais completos. Os contratos não vazios de `Groups`, `OnWorkflowEvent`, `ConstantValues` e os tipos concretos de `Logs`/`Traces` não estão completos no catálogo atual: nesses pontos só se aceitam valores Ruby tipados suportados, sem inventar um schema. |
| P2 | `lib/mxrb/forms/values.rb` | A correção de cópia defensiva cobre Text/Translation. Outros coercers usam `value.to_s.freeze`, que pode congelar a própria String recebida, e outros valores `Data` contêm componentes que merecem auditoria de imutabilidade profunda. Definir e testar um contrato uniforme de propriedade dos valores. |
| P2 | `lib/mxrb/pluggable/mpr_codec.rb`, `restore_schema_fields!` | A restauração de identidades internas usa pareamento posicional de arrays. O encoder atualmente deriva o schema da mesma baseline, o que sustenta esse pareamento no caminho observado. Uma futura edição/reordenação de schema deve usar chaves semânticas e testes próprios antes de ampliar esse contrato. |

## Avaliação da linguagem e arquitetura

O uso de `Data.define`, blocos Ruby, objetos de schema e separação entre codec e
emissor é adequado ao objetivo Ruby-first. As correções demonstram por que
`Data` sozinho não garante imutabilidade profunda e por que modelos imutáveis
compartilhados devem substituir parsing repetido. O desempenho deve continuar
sendo medido com o caminho público da DSL, além das rotinas internas.

Os builders dinâmicos já implementam `respond_to_missing?` junto de
`method_missing`. As próximas melhorias devem reforçar os contratos semânticos
e a rastreabilidade dos erros, com Ruby convencional para integração, em vez de
introduzir outra linguagem de declaração. A conclusão global permanece
dependente da matriz real de fixtures, da auditoria da fonte exportada e dos
validadores externos compatíveis com cada versão Mendix.
