# Cobertura Ruby nativa

Esta é a fonte de verdade para a expansão do compilador Ruby → Mendix. Uma
superfície só recebe o estado `native` quando possui testes de criar, alterar,
remover, reabrir o MPR e recompilar sem trocar identidades nativas. Preservar o
BSON no sidecar não conta como edição.

Atualização de 27 de setembro de 2026: a matriz abaixo é conservadora por
família, não uma porcentagem de conclusão. Domínio, segurança e operação já
possuem rotas de autoria incremental; variantes não representadas continuam
preservadas. Os contratos e limites verificados estão na
[revisão de Ruby e round-trip](../reviews/ruby-code-review-2026-09-05.pt-BR.md).

Estados:

- `native`: Ruby autoritativo materializa e atualiza o artefato no Studio Pro;
- `parcial`: existe projeção nativa, mas nem todas as variantes são editáveis;
- `preserved_native`: round-trip preserva o artefato opaco;
- `runtime_only`: executa no runtime MXRB, sem equivalente nativo automático.

| Superfície | Estado | Contrato atual / próximo gate |
|---|---|---|
| Entidades e DTOs não persistentes | native | criar/remover, persistência estável |
| Atributos | native | tipos, required, unique, default, docs, length, localize date e referência de enum |
| Associações locais e cross-module | native | criar/alterar/remover, tipo, owner, storage, docs, delete behavior e ID estável |
| Definições de enumeração | native | criar/renomear/remover, valores ordenados, captions por idioma, documentação e IDs estáveis |
| Constantes | parcial | autoria incremental com identidade privada; ampliar variantes |
| Regras de acesso de entidade | parcial | roles, CRUD, XPath e membros; ACLs ambíguas ainda exigem identidade explícita |
| Índices, system members, generalização e OQL view | parcial | autoria incremental e reconciliação privada; sem pareamento por posição |
| Lifecycle de entidade | parcial | callbacks cobertos; ampliar variantes e validação de handlers |
| Module roles e project security | parcial | roles, user roles, demo users e política de senha; ampliar variantes por versão |
| Microflows e nanoflows | parcial | grafo e ações mapeadas são native; ampliar todas as famílias de ações/eventos/splits |
| Páginas core | parcial | 41 widgets e 455 ocorrências passam MPR → Ruby → MPR e MxBuild 11.12.1; falta ampliar o runtime funcional |
| Layouts, page templates, snippets e building blocks | native | DSL Forms tipada; criar/alterar/remover, dois ciclos com IDs estáveis e MxBuild 11.12.1 sem problemas |
| Menus | parcial | captions localizadas, page/microflow, ícones, hierarquia e remoção autoritativa; ações desconhecidas ficam em fallback lossless |
| Navegação | parcial | perfis modernos e legados, home/login/not-found, títulos, flags offline e homes por papel; PWA e configurações offline desconhecidas permanecem opacas |
| Pluggable widgets | parcial | pacote MPK e propriedades; ampliar schema, actions e design properties |
| Scheduled events | parcial | bloco de configuração tipado e identidade privada; ampliar variantes |
| Expressões regulares | native | texto Mendix/JVM, criação, edição, remoção e renomeação não referenciada com identidade privada |
| REST publicado e mappings JSON | parcial | serviço, resources, operações, parâmetros, JSON/export mappings e autenticação suportada; variantes desconhecidas ficam lossless |
| REST consumido e OData consumido | parcial | chamadas REST tipadas e serviço OData básico com CSDL v4; ampliar auth, proxy, form-data e entidades validadas |
| OData publicado, App Services e Web Services | preserved_native | contratos publicados/consumidos e versões suportadas |
| Message definitions e mappings XML derivados | parcial | entidades/atributos expostos, import/export mappings e ações XML; ampliar árvores, associações e variantes |
| XSD/WSDL e outros import/export mappings | preserved_native | edição estrutural e referências estáveis |
| Java custom actions e connectors externos | runtime_only | adapter Ruby existe; próximo: documento/action nativo e package contract |
| Workflows e task pages | preserved_native | metamodelo, outcomes, timers, boundaries e segurança |
| Settings, runtime, theme/design system e resources | parcial | assets e tokens cobertos; ampliar settings nativos versionados |
| React/TypeScript convencional | runtime_only | vira nativo apenas como pluggable widget oficial |

## Ordem de implementação

1. domínio completo: associações, enums, constantes, access rules, índices,
   generalização, system members e OQL views;
2. security e operação: roles, demo users, settings e scheduled events;
3. linguagem de flows: ações, eventos, splits, loops, erros e chamadas;
4. UI: pages, layouts, snippets, menus, widgets e propriedades avançadas;
5. integrações: REST/OData/App/Web Services, mappings, Java e connectors;
6. workflows e superfícies restantes encontradas no corpus real;
7. certificação por versão com `mxbuild`, Studio Pro e comparação semântica.

Cada fase deve manter o comportamento fail-closed: uma variante desconhecida é
preservada e relatada, nunca silenciosamente convertida nem descartada.

## Cobertura verificável atual

A suíte estrita passou com 2.083 exemplos e mede 100,00% das
linhas (37.094/37.094) e 100,00% dos branches (16.086/16.086). Nenhum código
executável da biblioteca foi removido do denominador para atingir o gate. O CI
exige o mesmo piso de 100/100.

Cobertura de código 100/100 também não encerra cobertura funcional: integrações,
workflows e task pages continuam `preserved_native`, menus e várias outras
famílias seguem `parcial`; as 455 propriedades de Forms estão em 455/455 no
gate independente `studio_validated`.

## Documentos reutilizáveis de apresentação

`script/presentation_documents_gate` cria layouts, page templates, snippets e
building blocks por DSL Forms tipada, exporta Ruby legível e recompila o MPR por
dois ciclos. O gate exige validação estrutural, documentos semanticamente
estáveis e preservação dos IDs da unidade e dos nós internos. Com
`--mxbuild /caminho/para/mxbuild`, o MxBuild 11.12.1 oficial empacota o artefato
final; o fixture certificado passa com código de saída zero e zero problemas.

Menus semanticamente suportados também são autoritativos: adicionar, alterar e
remover documentos ou itens preserva as identidades compatíveis, inclusive em
dois ciclos. Captions localizadas, destinos page/microflow, glyph icons e itens
recursivos são Ruby legível. Ações ou ícones desconhecidos exportam
`deep_structure` lossless, por isso a família permanece `parcial`. O fixture
`spec/fixtures/menu_documents/project.rb` passou no `script/frontend_acceptance`
com MxBuild 11.12.1 para original e reconstruído, sem erros e sem diferenças
estruturais.

## REST publicado e mappings JSON

O fixture `spec/fixtures/published_rest/project.rb` declara um serviço REST
com resources, operações GET/POST, parâmetros de path, microflows e
status de sucesso. O compilador infere estruturas JSON e export mappings
tipados para retornos de entidade/lista. Dois ciclos Ruby → MPR mantêm os IDs
das units, produzem fonte sem `deep_structure` e permanecem semanticamente
idênticos. O `script/frontend_acceptance` também aprovou original e
reconstruído no MxBuild 11.12.1, com zero erros e `frontend_ready: true`.

O estado permanece `parcial`: apenas shapes reconhecidos são emitidos pela DSL;
operações, autenticação ou mappings ainda não representados continuam no
fallback lossless em vez de serem parcialmente convertidos.

## REST consumido e OData consumido

O fixture `spec/fixtures/consumed_services/project.rb` combina uma chamada
REST GET sem body, parâmetros de URL, headers ordenados, timeout e resposta
HTTP com um serviço OData consumido baseado em CSDL v4 e URL definida por uma
constante Mendix. Dois ciclos Ruby → MPR mantêm semântica e IDs das units sem
`native_fragment`, `deep_structure` ou BSON opaco nas fontes certificadas.
Original e reconstruído também passaram no MxBuild 11.12.1 com zero erros,
zero diferenças estruturais e `frontend_ready: true`.

Chamadas sem body usam o `CustomRequestHandling` vazio observado em projetos
reais. A DSL rejeita mapping sem variável, variável sem mapping e a mistura de
body customizado com export mapping. A família permanece `parcial`: form-data,
variantes de autenticação/proxy, referências de metadata e entidades OData
validadas ainda seguem pelo fallback lossless quando não são reconhecidas.

## Message definitions e mappings XML derivados

O fixture `spec/fixtures/message_xml/project.rb` declara entidade e atributos
expostos por uma `MessageDefinitionCollection`, import/export mappings com
`XmlPath` e duas microflows que importam e exportam XML. Dois ciclos Ruby → MPR
mantêm a semântica e os IDs das units sem `native_document`, `deep_structure`,
`native_fragment` ou BSON opaco nas fontes certificadas. Original e
reconstruído passaram no MxBuild 11.12.1 com zero erros, zero diferenças
estruturais e `frontend_ready: true`.

Mappings baseados em message definitions não ativam validação contra schema,
pois o próprio MxBuild reserva essa opção para mappings XSD. A família segue
`parcial`: árvores aninhadas, associações, conversores, XSD/WSDL e outras
variantes permanecem no fallback lossless até receberem evidência específica.

## Propriedades de Forms core

`script/forms_core_project_gate` cria um MPR 11.12.1 com uma ocorrência
isolada de cada propriedade herdada dos 41 widgets concretos, exporta o modelo
como Ruby legível, recompila e reabre o MPR tipado. O gate cobre 455/455 nas
fases `imported` e `compiled`, além das 455/455 já cobertas por representação,
emissão, transcodificação e round-trip sintético. Um segundo MPR usa witnesses
completos nos contextos de layout, template, entidade, arquivo e imagem. O
MxBuild 11.12.1 oficial o empacota com zero problemas, e a inspeção tipada desse
mesmo artefato certifica `studio_validated` em 455/455. O `TemplatePlaceholder`
legado é carregado em um template explicitamente excluído, pois o próprio
Studio o proíbe em documentos implantáveis.

## Enumerações em aplicações Ruby

O export `--mode ruby` cria uma classe em `app/enumerations/<módulo>/`. Os IDs
nativos permanecem no vínculo privado do projeto exportado; não são
necessários nas declarações geradas:

```ruby
module Pedidos
  class Status < Mxrb::RubyApp::Enumeration
    mendix_name 'Pedidos.Status'
    documentation 'Situação atual do pedido'

    value 'Aberto' do
      translation 'en_US', 'Open'
      translation 'pt_BR', 'Aberto'
    end
    value 'Fechado' do
      translation 'en_US', 'Closed'
      translation 'pt_BR', 'Fechado'
    end
  end
end
```

`id:` e `captions:` continuam aceitos por compatibilidade. Use
`value 'Novo', renamed_from: 'Anterior'` para renomear um valor sem publicar
seu ID. `remove_value 'Anterior'` desambigua remoção seguida de inserção; sem
uma indicação inequívoca, a operação é recusada. A ordem das
chamadas `value` é autoritativa. Remover o arquivo exclui a enumeração somente
quando não há atributo que a referencie; caso contrário a compilação falha antes
de escrever uma remoção insegura. Estruturas de localização e campos BSON não
representados na DSL são preservados pelo merge incremental.
