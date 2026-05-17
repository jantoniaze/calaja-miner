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

Para reinstalar em uma rig que ja possui `calaja-agent`, `xmrig` ou `/opt/calajaminer`, use instalacao limpa:

```bash
curl -fsSL https://raw.githubusercontent.com/jantoniaze/calaja-miner/main/scripts/install-calaja-miner.sh \
  -o /tmp/install-calaja-miner.sh

sudo env FRESH_INSTALL=true bash /tmp/install-calaja-miner.sh
```

Por padrao, a instalacao limpa cria backup de `/opt/calajaminer` antes de remover a versao antiga:

```text
/opt/calajaminer.backup.YYYYMMDDHHMMSS
```

Para reinstalar sem backup:

```bash
sudo env FRESH_INSTALL=true BACKUP_OLD=false bash /tmp/install-calaja-miner.sh
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
- para `calaja-agent` e `xmrig` antes de reinstalar;
- remove unit files antigos;
- cria backup opcional de `/opt/calajaminer`;
- instala arquivos em `/opt/calajaminer`;
- cria o venv do agent;
- instala dependencias Python;
- configura rig/worker automaticamente pelo IP;
- instala e habilita `xmrig.service` e `calaja-agent.service`;
- inicia os servicos.
