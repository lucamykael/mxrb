# Runtime sem Java

O modo Ruby executa o backend sem iniciar o Mendix Runtime Java. Ao abrir uma
aplicação exportada, o MXRB migra automaticamente um banco SQLite por ambiente,
abre o interpretador de microflows, registra lifecycle hooks, aplica segurança e
inicia os scheduled events.

```text
config/environments/
├── development.env
├── qa.env
├── staging.env
└── production.env
```

A precedência é `ENV do processo > config/environments/<ambiente>.env >
.env.<ambiente> > .env`. Selecione o perfil com `--environment qa` ou
`MXRB_ENV=qa`. `mxrb env . --environment qa` lista somente nomes de chaves e
fontes; valores nunca são impressos.

```bash
mxrb run . --environment qa
mxrb test App.mpr smoke.rb --native --environment qa
```

Cada perfil usa, por padrão, `.mxrb/runtime/<ambiente>.sqlite3`. O schema deriva
de entidades, atributos, associações e system members; mudanças aditivas são
aplicadas de forma idempotente e mudanças incompatíveis usam rebuild
transacional. Entidades não persistentes continuam somente em memória.

A API Ruby oferece login e tokens bearer, sessão, schema, navigation, pages,
microflows, CRUD e published REST. Regras de página/microflow, access rules de
entidade, direitos por member e o subconjunto seguro de XPath são verificados em
cada requisição. Credenciais vêm de `MXRB_USERS_JSON` e `MXRB_AUTH_TOKENS`; use
arquivos locais ignorados pelo Git ou o secret manager do deployment.

Scheduled events usam o scheduler stdlib do MXRB, com intervalos de minuto,
hora e dia, prevenção de overlap e encerramento supervisionado. Falhas ficam
disponíveis no scheduler e não derrubam silenciosamente o servidor. Zonas IANA,
como `America/Boa_Vista`, usam `tzinfo`, inclusive nas transições de horário de
verão. Zonas desconhecidas geram erro em vez de cair silenciosamente para UTC;
`UTC`, `local` e offsets numéricos como `-04:00` também são aceitos.

Java Custom Actions são a exclusão intencional: o runtime falha com mensagem
explícita. REST, app services, SOAP, mappings e geração de documentos podem usar
adapters Ruby injetados. O frontend continua JavaScript/React no navegador, mas
é servido e atendido pelo backend Ruby, sem Runtime Java.
