# Aceitação end-to-end do VetClinic

O projeto de aceitação foi removido e recriado do zero com `mxrb init`. Todos
os geradores foram exercitados antes do preenchimento das regras de negócio:
entidades, enumerações, use cases, validações, queries, repository, constante,
scheduled event, apresentação, página, nanoflow, segurança, integrações, REST,
Java Action, design, CI, teste funcional e avaliação arquitetural.

## Resultado dos gates

- validação estrutural MXRB: aprovada;
- lint semântico: 0 erros e 0 avisos;
- avaliação arquitetural: 100%;
- `mx check` oficial Mendix 11.12.1: 0 erros;
- `mxbuild`: build concluído e pacote MDA gerado;
- Runtime Mendix sincronizado: teste funcional `ACT_CreateAnimal` aprovado;
- regressão do MXRB: 622 exemplos, 0 falhas;
- cobertura: 100% de linhas e 100% de branches;
- RuboCop: 0 infrações.

O modelo cobre enumerações, seis entidades de negócio, generalização de
`System.User`, membros de sistema, regras de acesso, índices simples e
compostos, associações N:1, N:N e 1:1, microflows, nanoflow, página, navegação e
scheduled event.

## Trabalho que continua intencionalmente manual

Scaffold é estrutura, não especificação de negócio. Foi necessário escrever
atributos, regras, ações dos fluxos, valores de enumeração, permissões, teste e
avaliação. O VetClinic original teve a navegação conectada no `project.rb`;
depois desse aceite, `init` passou a criar perfil, layout e Home mínimos. Itens
de menu adicionais ainda não têm comando próprio. Página, integrações e
endpoints também exigem conteúdo real.

`published-rest`, `consumed-rest` e `java-action` produzem adaptadores de
microflow compiláveis. Um documento REST publicado/consumido ou Java Action
nativo ainda requer um baseline exportado ou Studio Pro. Isso não impede a
validade e o build do MPR aceito, mas delimita honestamente o alcance atual
desses três scaffolds.

## Correções orientadas pelo aceite

O ciclo oficial revelou e corrigiu serialização moderna de projeto, módulo,
domain model, entidades, atributos, enumerações, associações, acesso, índices,
navegação, páginas, flows, scheduled events e textos; também corrigiu colisão
entre artefatos homônimos, referências de enum, role administrativa mínima,
cache/índice semântico e marcação de entry points. O writer passou a partir de
um seed oficial versionado e preserva os metadados obrigatórios do Mendix.
Um smoke test independente confirmou que o scaffold vazio atual também passa
em `mx check` e MxBuild sem edição manual.
