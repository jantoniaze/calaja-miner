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

Se o repositorio estiver privado, use um token do GitHub com permissao de leitura:

```bash
export GITHUB_TOKEN="seu_token"

curl -H "Authorization: Bearer $GITHUB_TOKEN" \
  -fsSL https://raw.githubusercontent.com/jantoniaze/calaja-miner/main/scripts/install-calaja-miner.sh \
  -o /tmp/install-calaja-miner.sh

sudo env GITHUB_TOKEN="$GITHUB_TOKEN" bash /tmp/install-calaja-miner.sh
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
- instala arquivos em `/opt/calajaminer`;
- cria o venv do agent;
- instala dependencias Python;
- configura rig/worker automaticamente pelo IP;
- instala e habilita `xmrig.service` e `calaja-agent.service`;
- inicia os servicos.
