# Validação Windows e Studio Pro com Omarchy

## Situação verificada em 12 de agosto de 2026

O host possui AMD-V e os módulos KVM carregados. O comando oficial disponível é:

```bash
omarchy windows vm install
```

O instalador do Omarchy usa `dockurr/windows`, RDP e uma pasta compartilhada em
`~/Windows`. Ele exige 74 GB livres antes da instalação padrão. Na verificação,
o filesystem de `/home` tinha 60 GB livres, portanto a instalação não foi
iniciada. O SSD secundário `/dev/sda1`, ext4 com label `storage`, foi montado
somente para leitura, apresentou 435 GB livres e foi desmontado sem alteração.

Para seguir com o instalador oficial é necessário primeiro escolher uma ação
consciente:

1. liberar pelo menos 14 GB no filesystem raiz; ou
2. preparar um destino gravável no SSD secundário e confirmar como o diretório
   da VM será integrado, sem mexer em `filmails` nem em outros dados existentes.

Não se deve contornar a checagem de espaço nem alterar os scripts instalados do
Omarchy. Depois de haver espaço:

```bash
omarchy windows vm install
omarchy windows vm status
omarchy windows vm start
```

## Checklist no Studio Pro

Copie o MPR compilado para a pasta compartilhada e, no Windows:

1. abra a cópia no Studio Pro da mesma versão declarada pelo projeto;
2. sincronize o App Directory;
3. confirme domínio, validações, páginas, navegação, microflows e nanoflows;
4. compile sem erros e execute localmente;
5. teste página → nanoflow → microflow → retorno visível;
6. feche sem conversão automática não revisada e guarde o log da versão.

Essa validação GUI complementa `mxbuild`; ela não substitui os gates Linux,
Docker, TypeScript e Chromium.
