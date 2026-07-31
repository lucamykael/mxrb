# Padrão arquitetural do mxrb

**Português** · [English](../en-US/architectural-standard.md) · [Deutsch](../de-DE/architectural-standard.md)

Este documento é normativo. Ele define como conceitos Mendix são representados
em um projeto Ruby do `mxrb`, independentemente de como o Studio Pro agrupa os
documentos visualmente.

## 1. Princípio central

Tipos técnicos não são camadas arquiteturais.

- microflow é um mecanismo de execução no servidor;
- nanoflow é um mecanismo de execução no cliente/dispositivo;
- page é um documento de apresentação;
- entity é um elemento do Domain Model;
- navigation e security são políticas transversais.

Portanto, um microflow **não é automaticamente um service**. Sua pasta é
determinada pela responsabilidade exercida.

## 2. Estrutura completa

```text
my_app/
├── project.rb
├── app/
│   ├── settings.rb
│   ├── security/
│   │   ├── security.rb
│   │   ├── user_roles.rb
│   │   └── role_mappings.rb
│   ├── navigation/
│   │   ├── navigation.rb
│   │   ├── responsive.rb
│   │   ├── phone.rb
│   │   ├── tablet.rb
│   │   └── native.rb
│   └── design_system/
│       ├── design_system.rb
│       ├── tokens.rb
│       ├── layouts.rb
│       └── components.rb
├── modules/
│   └── OrderManagement/
│       ├── module.rb
│       ├── domain/
│       │   ├── model.rb
│       │   ├── entities/
│       │   ├── enumerations/
│       │   ├── rules/
│       │   └── policies/
│       ├── application/
│       │   ├── application.rb
│       │   ├── use_cases/
│       │   ├── queries/
│       │   ├── validations/
│       │   ├── jobs/
│       │   └── ports/
│       ├── presentation/
│       │   ├── presentation.rb
│       │   ├── pages/
│       │   ├── client_actions/
│       │   ├── snippets/
│       │   └── view_models/
│       ├── infrastructure/
│       │   ├── infrastructure.rb
│       │   ├── integrations/
│       │   ├── persistence/
│       │   ├── mappings/
│       │   ├── actions/
│       │   └── endpoints/
│       └── security/
│           ├── security.rb
│           ├── module_roles.rb
│           ├── entity_access.rb
│           └── document_access.rb
├── themesource/
├── widgets/
├── javasource/
└── resources/
```

Nem toda aplicação precisa usar todas as pastas. Diretórios vazios podem ser
omitidos, mas um artefato existente deve respeitar esta classificação.

## 3. Mapeamento dos fluxos

### Organização por feature

As camadas controlam a direção das dependências, mas artefatos de uma mesma
tela devem permanecer próximos. A apresentação usa **vertical slices**:

```text
presentation/
├── presentation.rb
└── features/
    └── order_editor/
        ├── feature.rb
        ├── order_edit_page.rb
        ├── view_model.rb
        └── client_actions/
            ├── on_product_change.rb
            ├── on_quantity_change.rb
            └── on_submit.rb
```

`feature.rb` é o agregador da slice. A página e seus nanoflows ficam juntos
porque mudam pelos mesmos motivos. O caso de uso server-side chamado pela tela
continua em `application/use_cases/`; ele pode ser utilizado por outras páginas,
APIs ou jobs sem depender da UI.

Uma feature não é uma nova camada e não pode inverter dependências.

### Microflows

Microflows executam no servidor e podem usufruir de transação. Eles são
classificados pela responsabilidade:

| Responsabilidade | Pasta Ruby | Exemplo |
|---|---|---|
| Caso de uso | `application/use_cases/` | `place_order.rb` |
| Consulta/data source | `application/queries/` | `find_open_orders.rb` |
| Validação coordenada | `application/validations/` | `validate_checkout.rb` |
| Job/scheduled event | `application/jobs/` | `expire_reservations.rb` |
| Adapter de integração | `infrastructure/integrations/` | `send_order_to_erp.rb` |
| Endpoint publicado | `infrastructure/endpoints/` | `post_order.rb` |
| Operação técnica interna | `infrastructure/actions/` | `calculate_file_hash.rb` |

Não existe uma pasta genérica `services/`, pois ela normalmente mistura casos
de uso, domínio e infraestrutura.

### Nanoflows

Nanoflows executam no browser/dispositivo, não são transacionais e são
especialmente adequados a UI responsiva e offline-first. Eles ficam em:

```text
presentation/client_actions/
```

Responsabilidades permitidas:

- coordenar estado temporário de tela;
- validação imediata de formulário;
- abrir/fechar páginas;
- mostrar mensagens;
- manipular dados locais/offline;
- chamar um caso de uso no servidor e tratar seu resultado na UI.

Nanoflows não devem conter regras de negócio autoritativas. Uma regra que
protege integridade, dinheiro, autorização ou persistência deve existir no
domínio/aplicação do servidor, mesmo que haja uma validação equivalente no
cliente para melhorar a experiência.

### Eventos e callbacks

O nome `on_change` sozinho é ambíguo. O `mxrb` distingue quatro categorias:

| Categoria | Origem | Destino típico | Exemplo |
|---|---|---|---|
| Evento de widget | page/widget | nanoflow | campo `Quantity` mudou |
| Ação de página | page/button | nano ou microflow | salvar pedido |
| Lifecycle de entidade | runtime/domain model | microflow | before commit |
| Evento de domínio | caso de uso | handler de application | pedido confirmado |

Eventos de widget ficam declarados junto ao widget/página e apontam para uma
ação nomeada:

```ruby
page :OrderEdit do
  data_source query: :GetOrderForEdit

  number_input :Quantity do
    on_change nanoflow: :RecalculateOrderDraft
  end

  button :Save do
    on_click microflow: :PlaceOrder
  end
end
```

Lifecycle de entidade não deve ser usado como substituto genérico de caso de
uso. Ele é apropriado para invariantes que devem ocorrer em toda criação,
alteração ou remoção, independentemente do ponto de entrada:

```ruby
entity :Order do
  before_commit microflow: :ValidateOrderInvariant
  after_commit microflow: :PublishOrderChanged
end
```

Regras:

- `before_commit` pode validar e rejeitar a transação;
- `after_commit` não deve fingir atomicidade com a transação já concluída;
- callbacks não devem iniciar navegação ou manipular widgets;
- callbacks devem ser pequenos e delegar para regras/casos de uso;
- evitar cadeias ocultas de callbacks;
- cada ligação deve ser uma referência explícita, validada pelo `mxrb lint`;
- handlers precisam declarar parâmetros e retorno compatíveis com o evento.

### Grafo de relações

O `mxrb` deve construir um grafo tipado, não apenas procurar nomes:

```text
Page
 ├── data_source ──> Query
 ├── on_change ────> Nanoflow
 └── on_submit ────> UseCase Microflow

UseCase
 ├── reads/writes ─> Repository Port
 ├── applies ──────> Domain Rule
 └── emits ────────> Domain Event

Repository Port
 └── implemented_by > Mendix/External Adapter
```

Renomear um artefato deve atualizar referências pelo seu ID estável. Nome é
apenas a identidade legível e fallback para importação.

### Domain rules

Uma regra pura e reutilizável pertence a:

```text
domain/rules/
```

Se a regra somente decide permissão de negócio, use:

```text
domain/policies/
```

Se ela coordena repositórios, integrações ou múltiplas entidades, é um caso de
uso em `application/use_cases/`.

## 4. Dependências permitidas

```text
presentation ───────> application ───────> domain
                           ↑                  ↑
infrastructure ────────────┘                  │
security policies ───────────────────────────┘
```

Regras:

1. `domain` não depende de presentation, application ou infrastructure.
2. `application` depende do domain e declara ports para necessidades externas.
3. `infrastructure` implementa ports; não define regras de negócio.
4. `presentation` chama application; não chama adapters diretamente.
5. nanoflow pode chamar um microflow público de application.
6. um módulo não acessa documentos internos de outro módulo; usa sua API.
7. dependência circular entre módulos é proibida.

Uma page pode referenciar nanoflows da própria feature e operações públicas de
application. Ela não acessa repository ou integração diretamente.

## 4.1 Queries, repositories e persistência Mendix

Consulta não é sinônimo de repository.

- **Query** representa intenção de leitura da aplicação, como
  `FindOpenOrdersForCustomer`.
- **Repository port** representa um contrato de persistência necessário ao caso
  de uso, como `OrderRepository`.
- **Adapter** implementa o port usando Mendix, REST, OData ou outra fonte.
- **Data source** adapta uma query para uma page/widget.

Estrutura:

```text
application/
├── queries/
│   └── find_open_orders_for_customer.rb
└── ports/
    └── repositories/
        └── order_repository.rb

infrastructure/
└── persistence/
    ├── mendix/
    │   └── order_repository.rb
    └── external/
        └── erp_order_repository.rb
```

Para CRUD simples sobre entidades Mendix, não é obrigatório criar um repository
cerimonial. Um port deve existir quando há uma fronteira relevante: múltiplas
fontes, troca de implementação, integração externa, política de cache ou uma
necessidade real de desacoplamento.

Fluxo correto:

```text
Page -> DataSource/Query -> Repository Port -> Persistence Adapter
```

Fluxo proibido:

```text
Page -> SQL/REST/Database Adapter
```

## 5. API pública de módulo

Cada módulo deve poder ser tratado como componente substituível. Sua API pública
é composta por:

- microflows de application explicitamente exportados;
- entidades e associações cujo export level permite consumo;
- eventos/mensagens publicados;
- páginas deliberadamente reutilizáveis;
- contratos de integração.

Convenção:

```text
application/use_cases/public/
application/use_cases/internal/
```

O `mxrb lint` deverá impedir referência externa a documentos em `internal/`.

## 6. Security

Security possui dois níveis distintos.

### App security

Fica em `app/security/`:

- nível de segurança (`production` por padrão);
- user roles;
- mapeamento de user roles para module roles;
- usuário anônimo;
- política de senha;
- regras de administração de usuários.

Um user role representa a função do usuário no app. Cada user role deve mapear,
preferencialmente, para no máximo um module role de cada módulo.

### Module security

Fica em `modules/<Module>/security/`:

- module roles;
- acesso a entidades e membros;
- XPath constraints;
- acesso a páginas;
- acesso a microflows e nanoflows;
- acesso a REST/OData/GraphQL e datasets.

Princípios:

- deny by default;
- menor privilégio;
- regras explícitas para toda entidade persistente;
- segurança nunca depende apenas de ocultar menu ou botão;
- acesso de documento e acesso de entidade devem ser validados juntos;
- XPath de segurança deve ser testado por role;
- regras são aditivas no Mendix: conceder acesso em uma segunda regra amplia o
  acesso efetivo.

O menu esconder uma página não impede acesso por URL ou chamada direta.

## 7. Navigation

Navigation é configuração de app e fica em `app/navigation/`, não dentro de um
módulo de negócio.

Cada profile possui arquivo próprio:

- responsive web;
- responsive offline;
- phone;
- tablet;
- native;
- embedded, quando aplicável.

Cada profile declara:

- home page padrão;
- home page por user role;
- sign-in page;
- menu;
- parâmetros de sincronização offline;
- pages/microflows usados como destinos.

Navigation depende das APIs públicas dos módulos. Um módulo pode oferecer
destinos navegáveis, mas não deve controlar o menu global do app.

## 8. Design system

O design system possui duas partes.

### Contrato Ruby

Fica em `app/design_system/`:

- tokens semânticos;
- layouts autorizados;
- componentes/padrões de página;
- variantes e estados;
- regras de acessibilidade;
- convenções responsivas.

Tokens devem expressar intenção:

```ruby
color :surface_primary
color :text_danger
spacing :content_gap
radius :control
```

Evite nomes acoplados a valores como `blue_500` na API de negócio.

### Recursos Mendix

Permanecem nos locais nativos:

- `themesource/`;
- UI resources package;
- layouts;
- snippets;
- building blocks;
- page templates;
- pluggable widgets.

Páginas de módulos consomem o design system; não criam estilos isolados sem
justificativa.

## 9. Padrões de design

Padrões adotados:

- **Use Case/Interactor**: microflow de `application/use_cases`;
- **Ports and Adapters**: contratos em `application/ports`, implementação em
  `infrastructure`;
- **Repository**: somente quando uma abstração real de fonte de dados for
  necessária; não envolver CRUD Mendix mecanicamente;
- **Policy**: decisão de negócio pura em `domain/policies`;
- **Specification**: critérios reutilizáveis de seleção/validação;
- **Presenter/View Model**: transformação de dados para páginas;
- **Facade**: API pública estável do módulo;
- **Domain Event**: desacoplamento entre módulos quando consistência imediata
  não for necessária.

Não usar padrões apenas para reproduzir sintaxe de frameworks Ruby tradicionais.
O metamodelo e runtime Mendix continuam sendo a plataforma de execução.

## 10. Convenções de nomes

O nome Ruby do arquivo é `snake_case`; o nome Mendix permanece `PascalCase`.

```text
PlaceOrder       -> place_order.rb
OrderList        -> order_list.rb
CustomerAddress  -> customer_address.rb
```

Prefixos Mendix podem ser reconhecidos na importação:

| Prefixo | Classificação padrão |
|---|---|
| `ACT_`, `IVK_` | `application/use_cases/` |
| `DS_`, `OQL_` | `application/queries/` |
| `VAL_` | `application/validations/` |
| `SUB_` | mesma camada do chamador; interno |
| `SE_` | `application/jobs/` |
| `API_` | `infrastructure/endpoints/` |
| `INT_` | `infrastructure/integrations/` |

Prefixos ajudam a importar projetos existentes, mas metadados explícitos devem
ter prioridade quando disponíveis.

## 11. Regras de qualidade automatizáveis

O futuro `mxrb lint` deve verificar:

- dependências entre camadas;
- ciclos entre módulos;
- documentos públicos sem documentação;
- entidade persistente sem access rules;
- página/microflow/nanoflow sem roles em security production;
- referência a documento interno de outro módulo;
- nanoflow contendo decisão autoritativa conhecida;
- endpoint chamando domínio sem passar por application;
- página fora do design system;
- navigation apontando para documento inexistente ou sem acesso;
- user role mapeado para múltiplos module roles do mesmo módulo;
- arquivos agregadores desatualizados.
- referência de evento inexistente ou com assinatura incompatível;
- page acessando repository/adapter diretamente;
- ciclo entre callbacks;
- lifecycle handler com efeito de apresentação;
- data source que executa comando/escrita sem declaração explícita;

## 12. Limite do suporte atual

Esta especificação define o formato-alvo. O writer/exporter atual cobre domínio,
microflows e nanoflows, páginas, menus, security e navigation nativa. Assets de
tema e código usam manifesto com checksum; tokens e políticas do design system
possuem contrato Ruby tipado. Workflows, integrações, APIs publicadas e widgets
sem API concisa continuam editáveis pelo Ruby profundo e pelo baseline nativo,
mas ainda precisam de DSLs tipadas específicas.

Até isso ocorrer, gere sobre uma cópia do MPR original para preservar units
desconhecidas.

O grafo tipado e a DSL dessas relações já validam referências ausentes,
dependências entre módulos, acesso direto indevido e ciclos de chamadas.
Nanoflows e entity lifecycle handlers possuem representação BSON. Conceitos sem
unit Mendix próprio, como repository ports, e eventos que ainda não possuem uma
árvore concreta de widgets são preservados na tabela `_MxrbArchitecture` dentro
do MPR. O exportador lê esse manifesto e recompõe a mesma DSL no round-trip.

Bindings ligados a widgets concretos de entrada e botões são serializados como
`Pages$TextBox`, `Pages$ActionButton`, `Pages$MicroflowClientAction` ou
`Pages$CallNanoflowClientAction`. Data sources de página são materializados em
um `Pages$DataView`.

Bindings abstratos sem widget concreto continuam preservados no manifesto. Eles
não devem ser apresentados como funcionalidade executável do app Mendix até
serem associados a um elemento `Pages$...`.
