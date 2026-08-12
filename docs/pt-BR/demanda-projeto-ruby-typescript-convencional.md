# Demanda: projetos Ruby e TypeScript convencionais

## Objetivo

Reduzir a presença visível de conceitos Mendix ao mínimo tecnicamente exigido
pela geração reversível do MPR. Um usuário deve desenvolver a aplicação como
um projeto Ruby e React + TypeScript normal, tanto ao partir de um MPR real
quanto ao iniciar do zero.

## Contrato obrigatório

- `app/` contém código Ruby convencional da aplicação.
- `frontend/src/app`, `components`, `core`, `features`, `hooks`, `layouts` e
  `styles` pertencem ao desenvolvedor e nunca são regenerados.
- `frontend/src/generated` é a única fronteira frontend controlada pelo MXRB.
- detalhes de documentos, widgets, microflows, nanoflows e IDs portáteis ficam
  na bridge gerada, não na superfície de features/componentes.
- projetos gerados têm lockfile, TypeScript estrito, lint, formatação, testes de
  componentes, testes unitários e build de produção.
- o round-trip preserva arquivos da aplicação byte a byte e substitui qualquer
  bridge gerada obsoleta pela projeção atual.
- entidades e atributos novos usam a forma BSON nativa do editor Mendix;
  `required: true` cria `DomainModels$RequiredRuleInfo` e pode ser alterado ou
  removido em round-trips posteriores.
- ícones de navegação aceitam nomes usuais da DSL (`home`, `calendar`, `tasks`,
  `checklist` etc.) e são materializados como códigos de glyph válidos.

## Certificação exigida

1. MPR real: exportar para Ruby/TypeScript, criar e alterar páginas e fluxos sem
   editar o MPR, recompilar, reexportar, executar no navegador e validar com as
   ferramentas oficiais Mendix disponíveis.
2. Projeto do zero: criar em Ruby/TypeScript, implementar página e fluxo,
   materializar o primeiro MPR, reexportar, executar e validar no Mendix.

Os dois casos devem provar frontend → fluxo local → backend Ruby → efeito de
retorno à página, IDs estáveis, build oficial sem erro e ausência de caminhos
locais ou segredos nos artefatos versionados.

O resultado e as evidências reproduzíveis ficam em
[`certificacao-ruby-typescript.md`](certificacao-ruby-typescript.md).
