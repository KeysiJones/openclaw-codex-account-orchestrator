# OpenClaw Codex Account Orchestrator

Ferramenta shell para orquestrar múltiplas contas OAuth do provider `openai-codex` no OpenClaw.

## Recursos

- Adicionar conta via wizard OAuth e renomear `default -> contaN`
- Transferir sessão para outra conta (mantendo contexto)
- Aplicar troca para uma sessão específica ou todas
- Definir conta principal para novas sessões (mantendo rodízio)
- Listar contas e ordem efetiva
- Mostrar conta usada por sessão
- Sincronizar `openclaw.json` com `auth-profiles.json`

## Uso

```bash
./openclaw-codex-account-orchestrator.sh
```

## Arquivos

- `openclaw-codex-account-orchestrator.sh`
- `index.html` (documentação da pesquisa)
