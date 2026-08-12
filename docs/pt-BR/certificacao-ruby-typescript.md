# Certificação Ruby + TypeScript ↔ Mendix

Status em 12 de agosto de 2026: **aprovado nos dois cenários**.

Esta certificação confirma que uma aplicação pode ser desenvolvida em Ruby e
React + TypeScript, materializada como MPR e reexportada sem perder o código da
aplicação. Os artefatos descartáveis são criados exclusivamente em `/tmp`.

## Caso 1 — MPR real

Base: VetClinic 11.12.1, armazenado fora do repositório do MXRB em
`$HOME/Personal_Projects/mxrb-projects/certification/vetclinic/VetClinic.mpr`.
O SHA-256 do original permaneceu inalterado.

Implementações feitas somente nas fontes exportadas:

- alteração da Home em Ruby;
- página `VetClinic.AppointmentBoard` em Ruby;
- microflows `ACT_RecordHomeAccess` e `ACT_RefreshAppointmentBoard` em Ruby;
- nanoflow `NAN_RefreshAppointmentBoard` chamando o microflow e mostrando o
  valor retornado na página;
- feature e rota `/workspace` escritas como React + TypeScript convencionais.

Resultados:

- validação e preflight MXRB: zero findings;
- MPR final: 231 units, 5 pages, 25 layouts, 4 nanoflows e 16 microflows;
- reexportação preservou os arquivos TypeScript manuais byte a byte;
- Prettier, ESLint, Vitest, TypeScript estrito e Vite passaram;
- MxBuild oficial 11.12.1: `BUILD SUCCEEDED`;
- Chromium: zero erros de console, microflow da Home por POST 200 e cadeia
  nanoflow → microflow → mensagem de retorno aprovada.

O cenário reproduzível é
`spec/fixtures/frontend_browser/vetclinic_real_project_flow.json`.

## Caso 2 — projeto criado do zero

Base criada com:

```bash
WORK="$(mktemp -d /tmp/mxrb-ruby-typescript.XXXXXX)"
bundle exec mxrb init "$WORK/CarePortal" --mode ruby --flymetothemoon
```

Implementações feitas somente em Ruby/TypeScript:

- entidade persistente `CarePortal.CareRequest`;
- `Title` obrigatório, `Priority` inteiro e `Resolved` booleano;
- Home e página `CarePortal.Operations`;
- microflows `ACT_CheckStatus` e `ACT_SyncQueue`;
- nanoflow `NAN_SyncQueue`, chamando o backend e devolvendo a mensagem à página;
- componente React `DeveloperWorkspace` e rota manual `/workspace`.

Resultados:

- MPR materializado: 14 units, zero erros e zero avisos no preflight;
- `Title` reaberto como `required: true`, com `RequiredRuleInfo` nativo;
- entidade escrita na forma nativa do editor (`Name`, `Attributes`,
  `ValidationRules`, `MaybeGeneralization`);
- MxBuild oficial 11.12.1: `BUILD SUCCEEDED`;
- round-trip preservou componente, teste e rotas TypeScript byte a byte;
- Prettier, ESLint, 4 testes Vitest, TypeScript estrito e Vite passaram;
- Chromium: zero erros de console; `ACT_CheckStatus` e `ACT_SyncQueue` responderam
  POST 200; o estado da rota React manual também foi atualizado.

O cenário reproduzível é
`spec/fixtures/frontend_browser/care_portal_zero_project_flow.json`.

## Gate reproduzível

```bash
bundle exec rspec
bundle exec rubocop

cd frontend
npm ci
npm run check
```

Para cada MPR final, execute ainda `mxrb validate`, `mxrb preflight` e o MxBuild
da mesma versão indicada no projeto. Evidências do Chromium ficam em
`tmp/browser-*`, que é ignorado pelo Git; cenários e expectativas permanecem
versionados.

## Falhas encontradas e corrigidas durante a certificação

- atributo obrigatório era recusado pelo contrato reversível;
- mutações incrementais escreviam entidades/atributos com casing de runtime em
  vez da forma nativa esperada pelo Studio Pro;
- o ícone comum `tasks` não era resolvido;
- o frontend exportado concentrava o runtime num único componente e misturava
  código da aplicação com projeções geradas;
- o round-trip podia restaurar uma bridge gerada antiga.

Essas falhas agora possuem regressões automatizadas ou cenários de navegador.
