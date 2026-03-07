# OpenClaw Codex Account Orchestrator

Orquestrador de múltiplas contas OAuth do provider `openai-codex` no OpenClaw, com foco em continuidade de uso quando uma conta atinge limite temporário.

## Problema

No fluxo OAuth padrão, o login de uma nova conta tende a usar o perfil `openai-codex:default`. Se você repetir o login sem organizar os perfis, pode sobrescrever a conta anterior e perder a estratégia de rodízio entre contas.

## Solução

Este projeto automatiza a gestão de contas OAuth do Codex com:

- criação incremental de perfis (`conta1`, `conta2`, `conta3`, ...)
- sincronização da configuração em `~/.openclaw/openclaw.json`
- definição de prioridade para novas sessões sem perder rodízio
- troca manual de conta por sessão (ou em todas as sessões listadas)
- inspeção de qual conta está em uso por sessão

## Como o rodízio funciona por baixo dos panos

- O rodízio é feito pelo runtime de auth/provider do OpenClaw, não por um “agente de rotação” separado.
- Em geral, sessões novas usam a ordem definida em `auth.order.openai-codex`.
- Quando uma conta/profile falha por limite/auth/billing, o runtime tenta o próximo perfil elegível.
- Se você fizer pin manual (`/model ...@profile`), aquela sessão fica presa nesse profile até remover override.

## Preservação de contexto

- Contexto da conversa fica na sessão do OpenClaw.
- Trocar a conta de uma sessão com `/model ...@profile` mantém o mesmo contexto da sessão.
- O que muda é o profile OAuth usado para autenticar as próximas chamadas daquela sessão.

## Script

Arquivo principal:

- `codex-orchestrator.sh`

Execução padrão (menu interativo):

```bash
./codex-orchestrator.sh
```

Também aceita parâmetros CLI (modo não interativo).

## Menu interativo

1. Adicionar nova conta (login + renomear `default -> contaN`)
2. Trocar conta (sessão específica ou todas) via `/model ...@profile`
3. Definir conta principal para novas sessões (mantendo rodízio)
4. Listar contas configuradas (`openai-codex`)
5. Mostrar conta usada por cada sessão
6. Sincronizar config apenas (`repair-config-only`)
7. Encerrar

## Fluxo recomendado para adicionar contas

1. Rodar a opção de adicionar nova conta.
2. Concluir login OAuth no wizard do OpenClaw.
3. Deixar o script renomear `openai-codex:default` para a próxima `contaN`.
4. Repetir para cada conta adicional.
5. Ajustar conta principal para novas sessões quando necessário.

## Comandos úteis do OpenClaw

Ver modelos e status de auth:

```bash
openclaw models
```

Ver canais/auth em JSON:

```bash
openclaw channels list --json
```

Ver sessões do agente:

```bash
openclaw sessions --agent main --json
```

Trocar model/profile na sessão atual (no chat):

```text
/model openai-codex/gpt-5.3-codex@openai-codex:conta2
```

Remover pin manual e voltar ao comportamento automático da sessão:

```text
/model openai-codex/gpt-5.3-codex
```

## Observações importantes

- Este projeto é focado em OAuth (não em API key).
- Compatibilidade depende da versão do OpenClaw e do fluxo OAuth disponível no seu ambiente.
- Em alguns ambientes, `openclaw models auth login --provider openai-codex` pode falhar; por isso o fluxo principal usa o wizard (`openclaw config`/`openclaw configure`).
- Use apenas contas autorizadas e em conformidade com os termos da plataforma.

## Estrutura do projeto

- `codex-orchestrator.sh`
- `README.md`

