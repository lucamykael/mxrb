# Padrões arquiteturais

**Português** · [English](../en-US/architectural-patterns.md) · [Deutsch](../de-DE/architectural-patterns.md)

O MXRB usa Ruby como única interface pública do modelo e organiza
responsabilidades em domínio, aplicação, apresentação e infraestrutura.

```text
apresentação ─┐
              ├─> aplicação ─> domínio
infraestrutura┘
```

Entidades e regras guardam o estado de negócio. Microflows são casos de uso
quando coordenam esse estado. Páginas, navegação e nanoflows ficam em
apresentação; HTTP, banco externo, Java e integrações ficam em infraestrutura.

Repositórios são úteis em fronteiras externas reais, não como cerimônia ao
redor do CRUD Mendix comum. Chamadas e dependências permanecem visíveis no
grafo semântico e podem ser validadas contra o modelo real.

Security, navigation e design system são políticas transversais em `app/`.
A navegação declarada também é gravada no documento nativo Mendix.

[Voltar ao índice](README.md)
