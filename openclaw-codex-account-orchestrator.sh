#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="main"
SKIP_LOGIN=0
COUNT=""
INTERACTIVE=0
REPAIR_CONFIG_ONLY=0

usage() {
  cat <<'EOF'
Uso:
  add-codex-account.sh [--agent <id>] [--count <n>] [--interactive] [--skip-login] [--repair-config-only]

Fluxo:
  1) Abre o wizard nativo do OpenClaw para login OAuth do Codex
  2) Renomeia openai-codex:default -> openai-codex:contaN (N incremental)

Opções:
  --agent <id>      Agent alvo (padrão: main)
  --count <n>       Adiciona N contas em lote (loop login + rename)
  --interactive     Abre menu interativo (também é o modo padrão sem parâmetros)
  --skip-login      Não executa login; só tenta renomear default -> contaN
  --repair-config-only  Só sincroniza openclaw.json (auth.profiles/auth.order) com auth-profiles.json
  -h, --help        Mostra esta ajuda

Exemplos:
  add-codex-account.sh --interactive
  add-codex-account.sh --count 2
  add-codex-account.sh --count 1 --agent main
  add-codex-account.sh --repair-config-only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      AGENT_ID="${2:-}"
      shift 2
      ;;
    --count)
      COUNT="${2:-}"
      shift 2
      ;;
    --interactive)
      INTERACTIVE=1
      shift
      ;;
    --skip-login)
      SKIP_LOGIN=1
      shift
      ;;
    --repair-config-only)
      REPAIR_CONFIG_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Argumento inválido: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -n "$COUNT" && ! "$COUNT" =~ ^[0-9]+$ ]]; then
  echo "Erro: --count deve ser inteiro >= 0" >&2
  exit 1
fi

if [[ $REPAIR_CONFIG_ONLY -eq 1 && ( -n "$COUNT" || $INTERACTIVE -eq 1 ) ]]; then
  echo "Erro: --repair-config-only não pode ser usado com --count ou --interactive." >&2
  exit 1
fi

resolve_openclaw_bin() {
  if [[ -n "${OPENCLAW_BIN:-}" && -x "${OPENCLAW_BIN}" ]]; then
    echo "$OPENCLAW_BIN"
    return 0
  fi
  if command -v openclaw >/dev/null 2>&1; then
    command -v openclaw
    return 0
  fi
  local candidates=(
    "$HOME/.nvm/versions/node/v24.13.1/bin/openclaw"
    "$HOME/.nvm/versions/node/v22.22.0/bin/openclaw"
    "$HOME/.nvm/versions/node/v20.18.0/bin/openclaw"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

OPENCLAW_BIN_PATH="$(resolve_openclaw_bin || true)"
if [[ -z "$OPENCLAW_BIN_PATH" ]]; then
  echo "Erro: comando 'openclaw' não encontrado." >&2
  echo "Defina OPENCLAW_BIN ou adicione openclaw ao PATH." >&2
  exit 1
fi

AUTH_FILE="$HOME/.openclaw/agents/$AGENT_ID/agent/auth-profiles.json"
CONFIG_FILE="$HOME/.openclaw/openclaw.json"
LAST_NEW_PROFILE_ID=""

resolve_config_file() {
  local cfg
  cfg="$("$OPENCLAW_BIN_PATH" config file 2>/dev/null || true)"
  if [[ -n "$cfg" ]]; then
    CONFIG_FILE="${cfg/#\~/$HOME}"
  fi
}

show_profiles() {
  echo
  echo "Perfis openai-codex atuais:"
  if "$OPENCLAW_BIN_PATH" channels list --json 2>/dev/null \
      | node -e '
        const fs = require("fs");
        const raw = fs.readFileSync(0, "utf8");
        const j = JSON.parse(raw);
        const rows = (j.auth || []).filter(a => a.provider === "openai-codex");
        if (!rows.length) process.exit(2);
        for (const r of rows) console.log(`- ${r.id} (${r.type})`);
      ' 2>/dev/null; then
    return 0
  fi

  node - "$AUTH_FILE" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
if (!fs.existsSync(file)) {
  console.log('(nenhum)');
  process.exit(0);
}
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const profiles = data.profiles || {};
const rows = Object.entries(profiles).filter(([, p]) => p && p.provider === 'openai-codex');
if (!rows.length) {
  console.log('(nenhum)');
  process.exit(0);
}
for (const [id, p] of rows) {
  console.log(`- ${id} (${p.type || 'unknown'})`);
}
NODE
}

get_primary_model_ref() {
  if [[ -f "$CONFIG_FILE" ]]; then
    jq -r '.agents.defaults.model.primary // empty' "$CONFIG_FILE" 2>/dev/null || true
  fi
}

get_provider_limits_label() {
  local label=""
  label="$("$OPENCLAW_BIN_PATH" channels list --json 2>/dev/null | node -e '
    const fs = require("fs");
    try {
      const j = JSON.parse(fs.readFileSync(0, "utf8"));
      const providers = j?.usage?.providers || [];
      const p = providers.find((x) => x.provider === "openai-codex");
      if (!p || !Array.isArray(p.windows) || p.windows.length === 0) process.exit(2);
      const byLabel = (name) => p.windows.find((x) => String(x.label || "").toLowerCase() === name);
      const w5h = byLabel("5h");
      const wWeek = byLabel("week");
      const fmt = (prefix, w) => {
        if (!w) return null;
        const used = Number(w.usedPercent);
        if (!Number.isFinite(used)) return null;
        const avail = Math.max(0, Math.min(100, Math.round(100 - used)));
        return `${prefix}: ${avail}% livre`;
      };
      const parts = [];
      const p5 = fmt("5h", w5h);
      const pW = fmt("semana", wWeek);
      if (p5) parts.push(p5);
      if (pW) parts.push(pW);
      if (!parts.length) {
        // fallback: first available window only
        const w = p.windows[0];
        const used = Number(w.usedPercent);
        if (!Number.isFinite(used)) process.exit(2);
        const avail = Math.max(0, Math.min(100, Math.round(100 - used)));
        parts.push(`${String(w.label || "janela")}: ${avail}% livre`);
      }
      process.stdout.write(parts.join(" | "));
    } catch {
      process.exit(2);
    }
  ' 2>/dev/null || true)"
  if [[ -n "$label" ]]; then
    echo "$label"
  else
    echo "N/D"
  fi
}

list_openai_codex_accounts() {
  if [[ ! -f "$AUTH_FILE" ]]; then
    echo "Nenhum auth store encontrado em $AUTH_FILE"
    return 0
  fi

  echo
  echo "Contas configuradas (openai-codex):"
  local limits_label
  limits_label="$(get_provider_limits_label)"
  AVAIL_LABEL="$limits_label" node - "$AUTH_FILE" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const pct = process.env.AVAIL_LABEL || 'N/D';
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const rows = Object.entries(data.profiles || {})
  .filter(([id, p]) => id.startsWith('openai-codex:') && p && p.provider === 'openai-codex')
  .map(([id, p]) => ({ id, type: p.type || 'unknown', expires: p.expires || null }))
  .sort((a, b) => a.id.localeCompare(b.id));
if (!rows.length) {
  console.log('(nenhuma)');
  process.exit(0);
}
for (const r of rows) {
  const conta = r.id.replace(/^openai-codex:/, '');
  const contaPct = `"${conta}(${pct})"`;
  const exp = r.expires ? new Date(r.expires).toISOString() : '-';
  console.log(`- ${contaPct} | profile=${r.id} (${r.type}) expires=${exp}`);
}
NODE

  echo
  echo "Ordem atual para novas sessões (ordem efetiva):"
  local printed=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "- $line"
    printed=1
  done < <("$OPENCLAW_BIN_PATH" models auth order get --provider openai-codex --agent "$AGENT_ID" --json 2>/dev/null | jq -r '.order[]?' 2>/dev/null || true)

  if [[ $printed -eq 0 && -f "$CONFIG_FILE" ]]; then
    jq -r '.auth.order["openai-codex"] // [] | .[]' "$CONFIG_FILE" 2>/dev/null | sed 's/^/- /' || true
  fi
}

show_session_account_mapping() {
  local sessions_file="$HOME/.openclaw/agents/$AGENT_ID/sessions/sessions.json"
  if [[ ! -f "$sessions_file" ]]; then
    echo "Arquivo de sessões não encontrado: $sessions_file"
    return 0
  fi

  echo
  echo "Conta em uso por sessão ($AGENT_ID):"
  local limits_label
  limits_label="$(get_provider_limits_label)"
  AVAIL_LABEL="$limits_label" jq -r '
    to_entries[]
    | .value as $s
    | ($s.authProfileOverride // "") as $p
    | (
        if ($p | test("^openai-codex:conta[0-9]+$"))
        then ($p | sub("^openai-codex:"; ""))
        elif ($p == "")
        then "auto"
        else $p
        end
      ) as $conta
    | "\($s.sessionId) | conta=\"\($conta)(" + (env.AVAIL_LABEL // "N/D") + ")\" | profile=\($s.authProfileOverride // "-") | source=\($s.authProfileOverrideSource // "-") | model=\($s.modelProvider // "-")/\($s.model // "-") | updatedAt=\($s.updatedAt // 0)"
  ' "$sessions_file" | sort -t'|' -k5,5r
}

switch_account_via_model() {
  if [[ ! -f "$AUTH_FILE" ]]; then
    echo "Erro: auth store não encontrado em $AUTH_FILE" >&2
    return 1
  fi

  local profiles=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && profiles+=("$line")
  done < <(node - "$AUTH_FILE" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const rows = Object.entries(data.profiles || {})
  .filter(([id, p]) => id.startsWith('openai-codex:') && p && p.provider === 'openai-codex')
  .map(([id]) => id)
  .sort((a, b) => {
    const ma = /^openai-codex:conta(\d+)$/.exec(a);
    const mb = /^openai-codex:conta(\d+)$/.exec(b);
    if (ma && mb) return Number(ma[1]) - Number(mb[1]);
    if (ma) return -1;
    if (mb) return 1;
    return a.localeCompare(b);
  });
for (const id of rows) console.log(id);
NODE
)

  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo "Nenhum perfil openai-codex encontrado."
    return 1
  fi

  echo
  echo "Perfis disponíveis:"
  local i
  for ((i=0; i<${#profiles[@]}; i++)); do
    printf "%d) %s\n" "$((i+1))" "${profiles[$i]}"
  done
  printf "Escolha o perfil [1-%d]: " "${#profiles[@]}"
  read -r pidx
  if [[ ! "$pidx" =~ ^[0-9]+$ ]] || (( pidx < 1 || pidx > ${#profiles[@]} )); then
    echo "Escolha inválida."
    return 1
  fi
  local profile_id="${profiles[$((pidx-1))]}"

  local sessions=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && sessions+=("$line")
  done < <("$OPENCLAW_BIN_PATH" sessions --agent "$AGENT_ID" --json 2>/dev/null | node -e '
    const fs = require("fs");
    const raw = fs.readFileSync(0, "utf8");
    const j = JSON.parse(raw);
    for (const s of (j.sessions || [])) {
      const profile = s.authProfileOverride || "";
      let conta = "auto";
      const m = /^openai-codex:conta(\d+)$/.exec(profile);
      if (m) conta = `conta${m[1]}`;
      else if (profile) conta = profile;
      console.log(`${s.sessionId}\t${s.modelProvider || "-"}\t${s.model || "-"}\t${s.updatedAt || 0}\t${conta}`);
    }
  ' 2>/dev/null || true)

  if [[ ${#sessions[@]} -eq 0 ]]; then
    echo "Nenhuma sessão encontrada para agent '$AGENT_ID'."
    echo "Dica: abra uma sessão no OpenClaw e tente novamente."
    return 1
  fi

  echo
  echo "Sessões recentes (mais nova primeiro):"
  local limits_label
  limits_label="$(get_provider_limits_label)"
  for ((i=0; i<${#sessions[@]} && i<8; i++)); do
    IFS=$'\t' read -r sid prov model upd conta <<<"${sessions[$i]}"
    printf "%d) %s | %s/%s | conta=\"%s(%s)\"\n" "$((i+1))" "$sid" "$prov" "$model" "$conta" "$limits_label"
  done
  echo "0) Todas as sessões listadas (${#sessions[@]})"
  printf "Escolha a sessão [ENTER=1, 0=todas]: "
  read -r sidx
  if [[ -z "$sidx" ]]; then sidx=1; fi
  if [[ ! "$sidx" =~ ^[0-9]+$ ]] || (( sidx < 0 || sidx > ${#sessions[@]} )); then
    echo "Sessão inválida."
    return 1
  fi

  local model_ref
  model_ref="$(get_primary_model_ref)"
  if [[ -z "$model_ref" ]]; then
    model_ref="openai-codex/gpt-5.3-codex"
  fi

  local slash_cmd
  slash_cmd="/model ${model_ref}@${profile_id}"
  echo
  if (( sidx == 0 )); then
    echo "Aplicando comando em TODAS as sessões:"
    echo "  $slash_cmd"
    local ok_count=0
    local fail_count=0
    local sid
    for line in "${sessions[@]}"; do
      IFS=$'\t' read -r sid _ _ _ _ <<<"$line"
      if "$OPENCLAW_BIN_PATH" agent --agent "$AGENT_ID" --session-id "$sid" --message "$slash_cmd" --json >/dev/null 2>&1; then
        ok_count=$((ok_count + 1))
      else
        fail_count=$((fail_count + 1))
      fi
    done
    echo "Concluído: $ok_count sucesso(s), $fail_count falha(s)."
  else
    local session_id
    IFS=$'\t' read -r session_id _ _ _ _ <<<"${sessions[$((sidx-1))]}"
    echo "Aplicando comando na sessão:"
    echo "  $slash_cmd"

    if "$OPENCLAW_BIN_PATH" agent --agent "$AGENT_ID" --session-id "$session_id" --message "$slash_cmd" --json >/dev/null 2>&1; then
      echo "Conta trocada na sessão $session_id para $profile_id"
    else
      echo "Falha ao enviar /model para a sessão."
      echo "Execute manualmente na conversa:"
      echo "  $slash_cmd"
      return 1
    fi
  fi
}

set_primary_profile_for_new_sessions() {
  if [[ ! -f "$AUTH_FILE" ]]; then
    echo "Erro: auth store não encontrado em $AUTH_FILE" >&2
    return 1
  fi

  local profiles=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && profiles+=("$line")
  done < <(node - "$AUTH_FILE" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const data = JSON.parse(fs.readFileSync(file, 'utf8'));
const rows = Object.entries(data.profiles || {})
  .filter(([id, p]) => id.startsWith('openai-codex:') && p && p.provider === 'openai-codex')
  .map(([id]) => id)
  .sort((a, b) => {
    const ma = /^openai-codex:conta(\d+)$/.exec(a);
    const mb = /^openai-codex:conta(\d+)$/.exec(b);
    if (ma && mb) return Number(ma[1]) - Number(mb[1]);
    if (ma) return -1;
    if (mb) return 1;
    return a.localeCompare(b);
  });
for (const id of rows) console.log(id);
NODE
)

  if [[ ${#profiles[@]} -eq 0 ]]; then
    echo "Nenhum perfil openai-codex encontrado."
    return 1
  fi

  echo
  echo "Definir conta principal para NOVAS sessões:"
  local i
  for ((i=0; i<${#profiles[@]}; i++)); do
    printf "%d) %s\n" "$((i+1))" "${profiles[$i]}"
  done
  printf "Escolha o perfil principal [1-%d]: " "${#profiles[@]}"
  read -r pidx
  if [[ ! "$pidx" =~ ^[0-9]+$ ]] || (( pidx < 1 || pidx > ${#profiles[@]} )); then
    echo "Escolha inválida."
    return 1
  fi

  local primary="${profiles[$((pidx-1))]}"
  local ordered=("$primary")
  for profile in "${profiles[@]}"; do
    if [[ "$profile" != "$primary" ]]; then
      ordered+=("$profile")
    fi
  done

  if "$OPENCLAW_BIN_PATH" models auth order set --provider openai-codex --agent "$AGENT_ID" "${ordered[@]}"; then
    echo "Ordem aplicada para novas sessões:"
    for profile in "${ordered[@]}"; do
      echo "- $profile"
    done
  else
    echo "Falha ao aplicar ordem via CLI." >&2
    return 1
  fi

  # Reconciliar metadata sem perder ordem explícita.
  sync_config_metadata || true
}
rename_default_to_next() {
  if [[ ! -f "$AUTH_FILE" ]]; then
    echo "Erro: arquivo não encontrado: $AUTH_FILE" >&2
    return 1
  fi

  local ts backup
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="$AUTH_FILE.bak.$ts"
  cp "$AUTH_FILE" "$backup"
  echo "Backup: $backup"

  local node_out rc
  set +e
  node_out="$(node - "$AUTH_FILE" <<'NODE'
const fs = require('fs');

const authFile = process.argv[2];
const fromId = 'openai-codex:default';

function renameDeep(value, from, to) {
  if (typeof value === 'string') return value === from ? to : value;
  if (Array.isArray(value)) return value.map((v) => renameDeep(v, from, to));
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      const newKey = k === from ? to : k;
      out[newKey] = renameDeep(v, from, to);
    }
    return out;
  }
  return value;
}

const raw = fs.readFileSync(authFile, 'utf8');
const data = JSON.parse(raw);
if (!data.profiles || !data.profiles[fromId]) {
  console.error(`Nenhum perfil '${fromId}' encontrado.`);
  process.exit(2);
}

let maxN = 0;
for (const id of Object.keys(data.profiles)) {
  const m = /^openai-codex:conta(\d+)$/.exec(id);
  if (m) maxN = Math.max(maxN, Number(m[1]));
}

let nextN = maxN + 1;
let toId = `openai-codex:conta${nextN}`;
while (data.profiles[toId]) {
  nextN += 1;
  toId = `openai-codex:conta${nextN}`;
}

const renamed = renameDeep(data, fromId, toId);
fs.writeFileSync(authFile, JSON.stringify(renamed, null, 2) + '\n', 'utf8');
console.log(`Renomeado: ${fromId} -> ${toId}`);
NODE
)"
  rc=$?
  set -e

  if [[ $rc -eq 2 ]]; then
    echo "Aviso: nenhum openai-codex:default para renomear."
    return 2
  fi
  if [[ $rc -ne 0 ]]; then
    echo "Erro ao processar auth-profiles.json."
    return $rc
  fi

  echo "$node_out"
  LAST_NEW_PROFILE_ID="$(printf '%s\n' "$node_out" | sed -n 's/^Renomeado: .* -> //p' | tail -n1)"
}

sync_config_metadata() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  [[ -f "$AUTH_FILE" ]] || return 0

  local ts backup
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="$CONFIG_FILE.bak.$ts"
  cp "$CONFIG_FILE" "$backup"

  local effective_order_json
  effective_order_json="$("$OPENCLAW_BIN_PATH" models auth order get --provider openai-codex --agent "$AGENT_ID" --json 2>/dev/null | jq -c '.order // []' 2>/dev/null || echo '[]')"

  EFFECTIVE_ORDER_JSON="$effective_order_json" node - "$CONFIG_FILE" "$AUTH_FILE" <<'NODE'
const fs = require('fs');
const cfg = process.argv[2];
const authFile = process.argv[3];
const oldId = 'openai-codex:default';

function byContaNumber(a, b) {
  const ma = /^openai-codex:conta(\d+)$/.exec(a);
  const mb = /^openai-codex:conta(\d+)$/.exec(b);
  if (ma && mb) return Number(ma[1]) - Number(mb[1]);
  if (ma) return -1;
  if (mb) return 1;
  return a.localeCompare(b);
}

const data = JSON.parse(fs.readFileSync(cfg, 'utf8'));
const authData = JSON.parse(fs.readFileSync(authFile, 'utf8'));
const effectiveOrder = (() => {
  try { return JSON.parse(process.env.EFFECTIVE_ORDER_JSON || '[]'); }
  catch { return []; }
})();
const storedProfiles = Object.entries(authData.profiles || {})
  .filter(([id, p]) => id.startsWith('openai-codex:') && p && p.provider === 'openai-codex')
  .map(([id]) => id)
  .sort(byContaNumber);

if (!data.auth || typeof data.auth !== 'object') data.auth = {};
if (!data.auth.profiles || typeof data.auth.profiles !== 'object') data.auth.profiles = {};
if (!data.auth.order || typeof data.auth.order !== 'object') data.auth.order = {};

// Remove metadata entries antigas de openai-codex para evitar drift.
for (const key of Object.keys(data.auth.profiles)) {
  if (key.startsWith('openai-codex:')) delete data.auth.profiles[key];
}

// Recria metadata a partir do auth-profiles.json (fonte de verdade dos tokens).
for (const id of storedProfiles) {
  data.auth.profiles[id] = { provider: 'openai-codex', mode: 'oauth' };
}

// Limpa default legado se sobrar em qualquer referência de order.
const existingOrder = (Array.isArray(effectiveOrder) && effectiveOrder.length)
  ? effectiveOrder.filter((id) => id !== oldId)
  : (Array.isArray(data.auth.order['openai-codex']) ? data.auth.order['openai-codex'].filter((id) => id !== oldId) : []);
const allowed = new Set(storedProfiles);
const nextOrder = [];
for (const id of existingOrder) {
  if (allowed.has(id) && !nextOrder.includes(id)) nextOrder.push(id);
}
for (const id of storedProfiles) {
  if (!nextOrder.includes(id)) nextOrder.push(id);
}
data.auth.order['openai-codex'] = nextOrder;

fs.writeFileSync(cfg, JSON.stringify(data, null, 2) + '\n', 'utf8');
console.log(`Config sync: openai-codex profiles=${storedProfiles.length}`);
NODE
}

add_one_account() {
  echo
  echo "=== Adicionar conta OAuth Codex (agent: $AGENT_ID) ==="
  if [[ $SKIP_LOGIN -eq 0 ]]; then
    echo "[1/2] Abrindo wizard OAuth..."
    echo "      No wizard, selecione OpenAI Codex OAuth e finalize o login."
    echo "      Tentando modo curto: config --section models"
    if ! "$OPENCLAW_BIN_PATH" config --section models; then
      echo "      Falhou modo curto. Abrindo wizard completo: openclaw config"
      "$OPENCLAW_BIN_PATH" config
    fi
  else
    echo "[1/2] Login pulado (--skip-login)."
  fi
  echo "[2/2] Renomeando default -> contaN..."
  LAST_NEW_PROFILE_ID=""
  rename_default_to_next || true
  sync_config_metadata || true
  show_profiles || true
}

run_count_mode() {
  local n="$1"
  if [[ "$n" -eq 0 ]]; then
    echo "Nada a fazer: --count 0"
    exit 0
  fi

  local i
  for ((i=1; i<=n; i++)); do
    echo
    echo "######## Iteração $i de $n ########"
    add_one_account
  done
}

run_interactive_menu() {
  while true; do
    echo
    echo "Menu - Codex OAuth ($AGENT_ID)"
    echo "1) Adicionar nova conta (login + renomear default -> contaN)"
    echo "2) Trocar conta (sessão específica ou todas) via /model ...@profile"
    echo "3) Definir conta principal para novas sessões (mantendo rodízio)"
    echo "4) Listar contas configuradas (openai-codex)"
    echo "5) Mostrar conta usada por cada sessão"
    echo "6) Sincronizar config apenas (repair-config-only)"
    echo "7) Encerrar"
    printf "Escolha [1-7]: "
    read -r choice

    case "$choice" in
      1)
        add_one_account
        ;;
      2)
        switch_account_via_model || true
        ;;
      3)
        set_primary_profile_for_new_sessions || true
        ;;
      4)
        list_openai_codex_accounts
        ;;
      5)
        show_session_account_mapping
        ;;
      6)
        sync_config_metadata
        show_profiles || true
        ;;
      7)
        echo "Encerrando."
        break
        ;;
      *)
        echo "Opção inválida."
        ;;
    esac
  done
}

resolve_config_file

if [[ -n "$COUNT" ]]; then
  run_count_mode "$COUNT"
  exit 0
fi

if [[ $INTERACTIVE -eq 1 ]]; then
  run_interactive_menu
  exit 0
fi

if [[ $REPAIR_CONFIG_ONLY -eq 1 ]]; then
  echo "=== Repair config only (agent: $AGENT_ID) ==="
  sync_config_metadata
  show_profiles || true
  exit 0
fi

# Comportamento padrão: menu interativo.
run_interactive_menu
