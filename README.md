# Meu agente pessoal de IA com memória

Um assistente de IA autônomo, rodando 24h numa VPS, com quem eu converso pelo Telegram. Ele é baseado no [Hermes Agent](https://github.com/NousResearch/hermes-agent) (open source, da Nous Research) e foi instalado e configurado por mim em Docker.

## O que ele faz

- **Lembra de mim entre conversas:** guarda preferências, contexto e decisões numa memória persistente, que sobrevive a reinícios e atualizações.
- **Aprende habilidades:** cria e reutiliza *skills* para tarefas recorrentes.
- **Executa tarefas, não só conversa:** pesquisa na web, navega em sites, roda código e manipula arquivos dentro de um ambiente isolado.
- **Trabalha sozinho:** tarefas agendadas (cron), como resumos diários enviados no Telegram.
- **Não fica fora do ar:** se o modelo principal (OpenAI) falhar ou ficar sem crédito, troca automaticamente para o Google Gemini.
- **Só obedece a mim:** responde apenas ao meu usuário do Telegram.

## O que este repositório mostra

A documentação da instalação, das decisões de configuração e da operação do agente: isolamento de rede, backup automático, atualização, controle de custos e os problemas que resolvi pelo caminho.

> ⚠️ **Nunca faça commit** do `.env`, da pasta `data/` nem dos arquivos de backup (`*.tar.gz`). Eles contêm as chaves da OpenAI, do Gemini e do Telegram.

---

## Visão geral

| Item | Valor |
|---|---|
| Servidor | Ubuntu 24.04, Docker 29, Compose v5 |
| Código do Hermes | `/opt/hermes/app` (clone do repositório oficial) |
| Dados do agente | `/opt/hermes/data` (config, memória, sessões, chaves) |
| Backups | `/opt/hermes/backups` |
| Container | `hermes` (serviço `gateway`) |
| Rede | `bridge`, isolada das outras aplicações da VPS |
| Modelo principal | OpenAI `gpt-4o-mini` |
| Modelo reserva (fallback) | Google Gemini, família Flash |
| Canal | Telegram, com allowlist (só o dono) |

```
/opt/hermes/
├── app/                          ← clone oficial (não editar, exceto o override)
│   └── docker-compose.override.yml
├── data/                         ← "mente" do agente (NUNCA no git)
│   ├── .env                      ← chaves de API
│   ├── config.yaml
│   ├── memories/ sessions/ skills/
├── backups/                      ← data-AAAA-MM-DD.tar.gz (NUNCA no git)
├── backup.sh                     ← script de backup diário
└── backup.log
/root/.hermes -> /opt/hermes/data ← link simbólico
```

---

## Instalação

### 1. Baixar o código e criar a pasta de dados

```bash
mkdir -p /opt/hermes
cd /opt/hermes
git clone https://github.com/NousResearch/hermes-agent.git app
mkdir -p data
```

> Dica: `git clone --depth 1` baixa só a versão atual (o histórico completo tem ~1,2 GB).

### 2. Construir a imagem

```bash
cd /opt/hermes/app
docker compose build
docker images | grep hermes
```

### 3. Apontar o volume para `/opt/hermes/data`

O compose oficial monta `~/.hermes`. Em vez de editar o arquivo oficial (o que geraria conflito no `git pull`), foi criado um link simbólico:

```bash
ln -s /opt/hermes/data /root/.hermes
chown -R 10000:10000 /opt/hermes/data
```

O processo dentro do container roda como o usuário `hermes` (UID 10000), sem poder de root.

### 4. Isolar a rede (override)

Copie o arquivo [`docker-compose.override.yml`](docker-compose.override.yml) para `/opt/hermes/app/`. O Compose lê esse arquivo automaticamente e troca `network_mode: host` por `bridge`.

```bash
cd /opt/hermes/app
docker compose config | grep network_mode   # deve mostrar "bridge" duas vezes
```

### 5. Assistente de configuração

```bash
cd /opt/hermes/app
docker compose run --rm -it gateway setup
```

Escolhas feitas:

| Tela | Escolha |
|---|---|
| Tipo de setup | Full setup |
| Provedor | OpenAI, Base URL padrão |
| Modelo | `gpt-4o-mini` |
| Terminal backend | Local (= dentro do container) |
| Plataforma | Telegram (manual, token do @BotFather) |
| Allowed users | ID numérico do dono (via @userinfobot) |
| Ferramentas | Padrão, **sem** Computer Use, Image Generation e Text-to-Speech |
| Navegador | Local Browser (Chromium headless) |
| Busca | Exa · Free (keyless) |
| Telemetria | No thanks |

### 6. Fallback para o Gemini

Chave criada em [aistudio.google.com](https://aistudio.google.com).

```bash
docker compose run --rm -it gateway fallback add    # provider: gemini, modelo Flash
docker compose run --rm gateway fallback list
docker compose restart gateway
```

O fallback entra em ação quando a OpenAI responde 429 (sem crédito ou limite de taxa), 401/403 ou 5xx. A troca vale por mensagem: na mensagem seguinte, o Hermes tenta a OpenAI de novo.

### 7. Subir o agente

```bash
cd /opt/hermes/app
docker compose up -d gateway
docker logs --tail 40 hermes      # procurar "Connected to Telegram (polling mode)"
```

---

## Operação diária

Sempre rodar os comandos do Compose dentro de `/opt/hermes/app`.

```bash
cd /opt/hermes/app
docker compose ps                     # está rodando?
docker logs --tail 50 hermes          # últimas linhas do log
docker logs -f hermes                 # log ao vivo (Ctrl+C sai)
docker stats --no-stream hermes       # CPU e RAM
docker compose restart gateway        # depois de mudar config.yaml ou .env
docker compose run --rm -it gateway tools   # ligar/desligar ferramentas
docker compose run --rm -it gateway model   # trocar o modelo
```

> Editar `config.yaml`, `.env` ou o compose **não altera** o container em execução. É preciso `restart` (config) ou `up -d` (compose).

Depois de qualquer `docker compose run`, confira se não sobrou container pendurado:

```bash
docker ps -a --filter name=gateway-run
docker rm -f NOME_DO_CONTAINER   # se sobrar algum
```

---

## Backup

O script [`backup.sh`](backup.sh) fica em `/opt/hermes/backup.sh`. Ele para o agente, compacta `/opt/hermes/data`, religa o agente (mesmo se der erro, por causa do `trap`) e apaga backups com mais de 14 dias.

```bash
chmod +x /opt/hermes/backup.sh
/opt/hermes/backup.sh             # testar à mão antes de agendar
```

Agendamento (`crontab -e`), em horário diferente dos outros backups da VPS para não disputarem disco:

```
30 3 * * * /opt/hermes/backup.sh >> /opt/hermes/backup.log 2>&1
```

A VPS está em UTC: 3h30 UTC = 0h30 em Brasília.

Conferir:

```bash
cat /opt/hermes/backup.log
ls -lh /opt/hermes/backups
```

O aviso `tar: data/gateway.sock: socket ignored` é normal.

### Restaurar (emergência)

```bash
cd /opt/hermes/app
docker compose stop gateway
mv /opt/hermes/data /opt/hermes/data.quebrado
tar xzf /opt/hermes/backups/data-AAAA-MM-DD.tar.gz -C /opt/hermes
docker compose start gateway
```

---

## Atualização

Ordem: **backup → pull → build → up**.

```bash
/opt/hermes/backup.sh
cd /opt/hermes/app
git fetch
git log --oneline HEAD..origin/main | head -20   # o que mudou
git pull
docker compose build
docker compose up -d gateway
docker logs --tail 40 hermes
docker image prune -f                            # remove imagens antigas
```

Depois de recriar o container, o aviso `Previous gateway life ... exited UNCLEANLY` é esperado.

---

## Segurança

Camadas de proteção:

1. **Allowlist do Telegram:** só o dono conversa com o agente.
2. **Ferramentas mínimas:** sem Computer Use, geração de imagem e TTS.
3. **Rede bridge:** o agente não alcança os serviços das outras aplicações publicados em `127.0.0.1` da VPS (bancos, cache, APIs).
4. **Usuário sem root** dentro do container (UID 10000).
5. **Permissões:** `.env` e backups com `chmod 600`.
6. **Painel (porta 9119) não exposto.** Para usar no futuro, só por túnel SSH.

Teste de isolamento (todos devem falhar):

```bash
docker exec hermes bash -c 'echo > /dev/tcp/127.0.0.1/5432 && echo ABERTO'
docker exec hermes timeout 5 bash -c 'echo > /dev/tcp/172.17.0.1/8081'; echo "codigo=$?"
```

`codigo=0` = aberto; `1` = recusado; `124` = bloqueado por tempo.

---

## Custos (OpenAI `gpt-4o-mini`)

Preço de referência: US$ 0,15 por 1M tokens de entrada e US$ 0,60 por 1M de saída. Confira em [openai.com/api/pricing](https://openai.com/api/pricing).

| Uso | Estimativa |
|---|---|
| Leve (~20 conversas/dia) | ~US$ 2/mês |
| Moderado (conversas + tarefas) | ~US$ 5–10/mês |
| Intenso (navegador, cron) | US$ 20+/mês |

Proteções: saldo pré-pago sem auto recharge e limite mensal em *Settings → Limits*. No Gemini grátis, o Google pode usar as conversas para treinar modelos: não enviar dados sensíveis.

---

## Problemas já resolvidos

| Sintoma | Causa | Solução |
|---|---|---|
| Comandos colados chegam quebrados | O terminal quebra linhas longas ao colar | Comandos curtos ou editar com `nano` |
| Override criado com heredoc não existia | Heredoc se perdeu na colagem | Link simbólico `/root/.hermes` (volume) e `nano` (override) |
| Menu mostra "Browser Use" ativo | Rótulo ambíguo da interface | A config real é `cloud_provider: local` (Chromium local); nada a corrigir |
| Bot sem resposta | API da OpenAI sem créditos | Recarregar créditos; fallback no Gemini |
| Fallback do Gemini com erro 404 | Modelo `gemini-2.5-flash-lite` indisponível | Trocar por um modelo Flash disponível (`fallback remove` + `fallback add`) |

Para listar os modelos que a chave do Gemini enxerga, sem expor a chave:

```bash
read -s GK
U=https://generativelanguage.googleapis.com/v1beta/models
curl -s -H "x-goog-api-key: $GK" $U | grep '"name"' | grep flash
unset GK
```

---

## Pendente: WhatsApp

Adiado até haver um chip com número separado.

- **Nunca** usar um número que outra aplicação já usa: um banimento derrubaria essa aplicação junto.
- Modo `bot`, com `WHATSAPP_ALLOWED_USERS` só com o número do dono (formato `5511999998888`, sem `+`).
- Desligar Terminal, Files e Code no canal do WhatsApp.
- Usar o chip normalmente por alguns dias antes de parear.
- A ponte usa Baileys (não oficial) e precisa de Node.js 18+ no container (`docker exec hermes node --version`).
- A sessão fica em `data/platforms/whatsapp/session` e deve ser tratada como senha.
