# calaja-miner

Snapshot inicial do no minerador CalajaMinerOS coletado do servidor de teste `192.168.3.15`.

## Estrutura

- `opt/calajaminer/`: aplicacao, agent, configuracoes, scripts e XMRig.
- `systemd/`: units usadas para iniciar os servicos do minerador.
- `scripts/install-calaja-miner.sh`: instalador automatico para novas rigs.
- `docs/`: notas do snapshot e inventario inicial.

## Origem

- Servidor: `home@192.168.3.15`
- Hostname: `CalajaMinerOS-17`
- Diretorio remoto: `/opt/calajaminer`

## Instalacao automatica em nova rig

Execute como `root` ou via `sudo` em uma rig Ubuntu/Debian:

```bash
curl -fsSL https://raw.githubusercontent.com/jantoniaze/calaja-miner/main/scripts/install-calaja-miner.sh | sudo bash
```

Em uma rig que ja possui `calaja-agent`, `xmrig` ou `/opt/calajaminer`, o instalador entra em modo de atualizacao automaticamente. Ele para os servicos, preserva configuracao da rig, atualiza os arquivos, garante o build do XMRig e inicia tudo novamente:

```bash
curl -fsSL https://raw.githubusercontent.com/jantoniaze/calaja-miner/main/scripts/install-calaja-miner.sh \
  -o /tmp/install-calaja-miner.sh

sudo bash /tmp/install-calaja-miner.sh
```

Para forcar explicitamente o modo de atualizacao:

```bash
sudo env INSTALL_MODE=update bash /tmp/install-calaja-miner.sh
```

Para reinstalar removendo arquivos antigos da versao anterior:

```bash
sudo env INSTALL_MODE=clean bash /tmp/install-calaja-miner.sh
```

Por padrao, a atualizacao e a instalacao limpa criam backup de `/opt/calajaminer` antes de alterar a versao antiga:

```text
/opt/calajaminer.backup.YYYYMMDDHHMMSS
```

Para reinstalar sem backup:

```bash
sudo env INSTALL_MODE=clean BACKUP_OLD=false bash /tmp/install-calaja-miner.sh
```

Para recompilar o XMRig mesmo quando ja existir um binario:

```bash
sudo env FORCE_XMRIG_BUILD=true bash /tmp/install-calaja-miner.sh
```

Variaveis principais:

```bash
CENTRAL_URL="http://192.168.3.3:5001/api/status"
POOL_URL="192.168.3.3:3333"
POOL_USER="wallet"
LOCATION="home"
WORKER="rig17"
RIG_ID="calaja-rig-17"
THREADS="15"
```

Exemplo com parametros:

```bash
curl -fsSL https://raw.githubusercontent.com/jantoniaze/calaja-miner/main/scripts/install-calaja-miner.sh -o /tmp/install-calaja-miner.sh

sudo env \
  CENTRAL_URL="http://192.168.3.3:5001/api/status" \
  POOL_URL="192.168.3.3:3333" \
  LOCATION="home" \
  bash /tmp/install-calaja-miner.sh
```

O instalador:

- instala dependencias do sistema;
- baixa este repositorio;
- detecta instalacoes antigas e servicos rodando;
- atualiza instalacao existente por padrao;
- preserva `rig_id`, `worker`, central, pool e configuracao principal;
- para `calaja-agent` e `xmrig` antes de atualizar;
- remove unit files antigos somente em `INSTALL_MODE=clean`;
- cria backup opcional de `/opt/calajaminer`;
- instala arquivos em `/opt/calajaminer`;
- cria o venv do agent;
- instala dependencias Python;
- compila o XMRig se `/opt/calajaminer/xmrig/build/xmrig` nao existir;
- configura rig/worker automaticamente pelo IP;
- instala e habilita `xmrig.service` e `calaja-agent.service`;
- inicia os servicos e mostra logs se algum deles falhar.
