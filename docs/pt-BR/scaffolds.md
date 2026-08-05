# Scaffolds de projeto

**Português** · [English](../en-US/scaffolds.md) · [Deutsch](../de-DE/scaffolds.md)

Todos os comandos aceitam `--target DIR`, recusam sobrescrever arquivos e
conectam automaticamente os agregadores `evaluate`/`evaluate_dir`. Use
`mxrb <comando> --help` para ver uso, destino e opções.

`--dry-run` mostra arquivos e agregadores sem gravar; `--json` produz saída
para automação. `mxrb scaffold list` lista geradores e instâncias registradas.
`mxrb scaffold destroy <kind:name>` remove somente arquivos que ainda possuem
o hash criado pelo gerador, protegendo edições posteriores.

| Comando | Resultado principal |
| --- | --- |
| `mxrb init App` | Projeto, módulo principal, perfil Responsive e página Home |
| `mxrb module new Billing` | Novo módulo conectado ao projeto |
| `mxrb entity new App.Customer` | `domain/entities/customer.rb` |
| `mxrb enumeration new App.Status` | `domain/enumerations/status.rb` |
| `mxrb constant new App.ApiUrl` | `domain/constants/api_url.rb` |
| `mxrb use-case new App.ACT_Create` | `application/use_cases/act_create.rb` |
| `mxrb validation new App.VAL_Customer` | `application/validations/val_customer.rb` |
| `mxrb query new App.QRY_Customers` | `application/queries/qry_customers.rb` |
| `mxrb repository new App.CustomerRepository` | Contrato e adaptador inicial |
| `mxrb scheduled-event new App.Cleanup` | Evento agendado e microflow |
| `mxrb presentation init App` | Pastas e agregador de apresentação |
| `mxrb page new App.CustomerOverview` | Página mínima com layout, título e roles comentados |
| `mxrb page templates` | Árvore de modelos de página auditados |
| `mxrb page new App.Dashboard --template dashboard` | Página baseada em modelo |
| `mxrb page new App.Order --chain page:nanoflow:microflow` | Fatia vertical executável |
| `mxrb nanoflow new App.NAN_OpenCustomer` | Nanoflow cliente |
| `mxrb security init App` | Papéis, `CheckEverything` no projeto e orientação de acesso |
| `mxrb demo-user new manager --role User` | Demo user com segredo local em `.env` |
| `mxrb integration new App.PetApi` | Adaptador de integração |
| `mxrb published-rest new App.CustomersApi` | Handler editável para REST publicado |
| `mxrb consumed-rest new App.ExternalPets` | Adaptador REST consumido |
| `mxrb java-action new App.ParseDocument` | Adaptador para Java Action |
| `mxrb functional-test new App.ACT_Create` | Definição de teste de runtime |
| `mxrb evaluation new architecture` | Avaliação estática do modelo |
| `mxrb design init` | Design system do projeto |
| `mxrb ci init github` | Workflow GitHub Actions |

Entidades começam vazias e apontam para o [guia completo da DSL](entity-dsl.md).
REST publicado e Java Action geram adaptadores Ruby: o documento/ação nativo
ainda deve vir do baseline exportado ou do Studio Pro. Os demais itens tipados
geram diretamente a DSL suportada pelo mxrb.

O gerador cria estrutura e conexão, não inventa regras de negócio. Atributos,
fluxos, widgets, permissões efetivas, URLs e credenciais continuam sendo
decisões do projeto. Páginas são esqueletos nativos mínimos; roles e conteúdo
ficam comentados até serem definidos. `init` cria o perfil Responsive e uma
página Home mínima para que o scaffold possa ser verificado e compilado
oficialmente. Outras páginas e itens de menu podem ser escritos na DSL Ruby.

`mxrb page new App.Order --chain ...` transforma o scaffold mínimo de página
em uma fatia vertical executável: gera entidade de amostra, microflow de data
source, formulário com campos e ações, página e item no perfil Responsive. Há
três cadeias de ação Mendix explícitas:

```sh
mxrb page new App.Order --chain page:microflow
mxrb page generate App.Order --chain page:nanoflow
mxrb page g App.Order --chain page:nanoflow:microflow
```

`page:microflow` chama o Runtime diretamente; `page:nanoflow` mantém a ação no
cliente; `page:nanoflow:microflow` usa o nanoflow como orquestrador cliente e
chama o microflow no Runtime. Todas criam `ACT_LoadOrder` para o data source;
as cadeias que terminam em microflow criam também `ACT_RefreshOrder`. Sem
`--chain`, `page new` preserva o esqueleto mínimo. `page generate` e `page g`
são aliases de `page new`. Cada cadeia é materializada em um MPR válido, serve
como ponto de partida removível e exercita o preflight do compilador; arquivos
existentes nunca são sobrescritos.

## Demo users

Depois de inicializar a segurança, um demo user pode ser declarado como um
arquivo Ruby independente:

```sh
mxrb security init App
mxrb demo-user new manager --entity System.User --role User
mxrb demo-user operator --entity App.Account --role User --role Administrator
```

`new` é opcional. `--entity` usa `System.User` por padrão e `--role` pode ser
repetido; sem ele, o papel `User` é usado. O scaffold valida imediatamente se
a entidade e os papéis existem, conecta `app/security/demo_users` ao bloco
`security` e habilita demo users no MPR.

A senha aleatória fica apenas no `.env` ignorado, com modo `0600` quando o
arquivo é criado. O Ruby gerado usa `ENV.fetch` e `.env.example` recebe somente
a variável vazia. Gere e valide o MPR normalmente depois do scaffold. Demo
users destinam-se a desenvolvimento e demonstração, não a usuários de produção.

## Modelos de página

No Mendix, page templates são pontos de partida: sua estrutura é copiada para
uma página comum e editável. O catálogo do MXRB expõe somente padrões que o
compilador e o Runtime já auditam:

```sh
mxrb page templates
mxrb page templates --json
mxrb page new App.Landing --template starter
mxrb page new App.Empty --template blank
mxrb page new App.Operations --template dashboard
mxrb page new App.Order_NewEdit --template form-vertical
```

`form-vertical` cria também entidade de amostra e `ACT_Load...` para o DataView.
Qualquer modelo pode receber `--chain`; por exemplo,
`--template dashboard --chain page:nanoflow` adiciona a ação cliente ao
dashboard. Esses nomes são contratos estáveis do MXRB inspirados nos padrões
Mendix, não uma promessa de importar silenciosamente todo template instalado
por Atlas ou Marketplace. Veja a [documentação oficial de páginas](https://docs.mendix.com/refguide/pages/).

Para um checkout local durante desenvolvimento:

```sh
mxrb init VetClinic --mxrb-path /caminho/para/mxrb
cd VetClinic
bundle install
bundle exec mxrb generate project.rb
bundle exec mxrb validate VetClinic.mpr
```
