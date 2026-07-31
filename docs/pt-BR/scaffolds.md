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
| `mxrb page new App.CustomerOverview` | Página com layout, título e roles comentados |
| `mxrb nanoflow new App.NAN_OpenCustomer` | Nanoflow cliente |
| `mxrb security init App` | Papéis, `CheckEverything` no projeto e orientação de acesso |
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
oficialmente. Outras páginas e itens de menu podem ser escritos no `project.rb`,
pois ainda não há um subcomando específico para inserir menus.

Para um checkout local durante desenvolvimento:

```sh
mxrb init VetClinic --mxrb-path /caminho/para/mxrb
cd VetClinic
bundle install
bundle exec mxrb generate project.rb
bundle exec mxrb validate VetClinic.mpr
```
