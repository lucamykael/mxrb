# Compilador e formato MDA

O `mxrb` possui um pipeline de compilação versionado que não executa `mx`,
`mxbuild`, `mxcli`, Studio Pro ou o Model SDK de forma implícita.

## Primeiro estágio: container MDA

```bash
mxrb pack Clinic.mpr --output build/Clinic.mda
mxrb mda inspect build/Clinic.mda
mxrb mda compare official.mda build/Clinic.mda
```

`pack` escreve o ZIP MDA inteiramente em Ruby, em ordem determinística e com
datas normalizadas. Por enquanto ele exige um diretório `deployment/` já
materializado. Essa exigência é verificada explicitamente; o comando nunca
chama o toolchain Mendix como fallback.

O deployment deve conter, no mínimo:

- `model/model.mdp`
- `model/metadata.json`
- `model/bundles/project.jar`
- `web/index.html`

Somente as raízes oficiais `model`, `web`, `native`, `sass` e `tmp` entram no
MDA. Diretórios de trabalho do Runtime e do Gradle, como `data`, `log`, `run`,
`build` e `.gradle`, são ignorados deliberadamente.

No teste de aceitação com VetClinic, o MDA escrito pelo MXRB foi extraído sobre
uma distribuição limpa do Runtime 11.12.1, criou/sincronizou 675 comandos de
banco e respondeu HTTP 200. Isso valida o container e os artefatos já
materializados; não significa que a materialização nativa das cinco etapas
abaixo esteja concluída.

Os adapters atuais reconhecem Mendix 9.x, 10.x e 11.x. A versão de
`model/metadata.json` deve corresponder exatamente à versão do MPR.

## Estágios seguintes

O container MDA não é o compilador completo. Os artefatos abaixo ainda precisam
ser materializados nativamente antes que um projeto novo dispense totalmente o
`mxbuild`:

1. `model/model.mdp` e metadados de persistência;
2. operações e metadados de microflows;
3. páginas, layouts, nanoflows e bundle React/Dojo;
4. `project.jar`, Java Actions e dependências;
5. imagem portátil do Runtime para os testes funcionais.

Cada estágio usa dispatch por versão. Recursos não implementados devem produzir
um erro de compilação claro; não existe fallback silencioso para `mx`/`mxbuild`.
