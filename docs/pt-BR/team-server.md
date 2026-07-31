# Team Server

O MXRB integra diretamente com o Team Server Git e com a App Repository API.
Nenhum comando usa `mx`, Studio Pro ou o Model SDK como intermediário.

```bash
mxrb team-server login --pat-file /caminho/seguro/team-server.env
mxrb team-server info a9e4af8a-2776-4b10-a471-8c42df8f5f43
mxrb team-server branches a9e4af8a-2776-4b10-a471-8c42df8f5f43
mxrb team-server clone \
  https://git.api.mendix.com/a9e4af8a-2776-4b10-a471-8c42df8f5f43.git \
  ./app
mxrb team-server pull ./app
mxrb team-server push ./app --branch main
```

## Credenciais

O modo recomendado armazena somente o caminho absoluto do arquivo informado em
`~/.config/mxrb/credentials`. O arquivo pode ser texto puro, JSON com
`team_server_pat`, ou `.env`:

```dotenv
MXRB_TEAM_SERVER_PAT=seu_pat
```

Também é possível definir `MXRB_TEAM_SERVER_PAT_FILE` sem executar `login`.
Se nenhum arquivo for configurado, operações Git usam o credential helper do
próprio usuário. A App Repository API exige um arquivo PAT.

O PAT nunca é incluído na URL, nos argumentos do processo ou no `.git/config`.
Durante operações Git ele é entregue por um `GIT_ASKPASS` temporário, apagado
imediatamente ao final.

Escopos:

- leitura: `mx:modelrepository:repo:read`;
- push: `mx:modelrepository:repo:write`.

## Limites oficiais

A Mendix informa que clones feitos fora do Studio Pro não recebem todo o
pós-processamento e metadados de revisão adicionados pelo Studio Pro. O MXRB
valida estruturalmente cada MPR após clone e pull, mas commits externos ainda
podem não conter metadados exigidos pelo deploy no Mendix Cloud. O compilador e
runtime próprios do MXRB não dependem desses metadados de Cloud.
