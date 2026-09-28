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
| REST publicado/consumido | preserved_native | serviços, resources, operations, mappings, auth e contratos |
| OData, App Services e Web Services | preserved_native | contratos publicados/consumidos e versões suportadas |
| Import/export mappings, JSON/XML/message definitions | preserved_native | edição estrutural e referências estáveis |
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

A suíte estrita passou com 2.080 exemplos e mede 100,00% das
linhas (37.076/37.076) e 100,00% dos branches (16.078/16.078). Nenhum código
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
