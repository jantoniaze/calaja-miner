# Snapshot do Servidor 192.168.3.15

Data da coleta: 2026-05-17

## Origem

- Servidor: `home@192.168.3.15`
- Hostname conhecido: `CalajaMinerOS-17`
- Diretorio principal remoto: `/opt/calajaminer`
- Services remotos: `/etc/systemd/system`

## Destino local

- Aplicacao: `server-snapshot/192.168.3.15/opt/calajaminer`
- Systemd: `server-snapshot/192.168.3.15/etc/systemd/system`

## Arquivos systemd coletados

- `calaja-agent.service`
- `calaja-firstboot.service`
- `xmrig.service`

## Pontos encontrados

- Agent local: `/opt/calajaminer/agent/agent.py`
- Config do agent: `/opt/calajaminer/agent/config.json`
- Config do XMRig: `/opt/calajaminer/config.json`
- Script first boot: `/opt/calajaminer/scripts/calaja-firstboot.sh`
- Script clone USB: `/opt/calajaminer/scripts/clone-usb-safe.sh`
- Binario XMRig: `/opt/calajaminer/xmrig/build/xmrig`

## Conexao com central

O agent esta configurado para enviar status para:

```text
http://192.168.3.3:5001/api/status
```

O XMRig esta configurado para usar pool em:

```text
192.168.3.3:3333
```

Isso indica que `192.168.3.3` provavelmente e o servidor `calaja-central` ou esta hospedando os servicos centrais/pool.

## Services

`calaja-agent.service` executa:

```text
/opt/calajaminer/agent/venv/bin/python /opt/calajaminer/agent/agent.py
```

`calaja-firstboot.service` executa:

```text
/opt/calajaminer/scripts/calaja-firstboot.sh
```

`xmrig.service` executa:

```text
/opt/calajaminer/xmrig/build/xmrig -c /opt/calajaminer/config.json
```

