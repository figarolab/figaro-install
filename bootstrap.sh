#!/usr/bin/env bash
# bootstrap.sh — Primo provisioning di un cliente in modalità registry (ROADMAP #49).
#
# È l'UNICO file che il vendor consegna out-of-band a un host nuovo (email/scp):
# clona il repo manifest PRIVATO al tag richiesto, semina config/registry.env col
# PAT del bot, e lancia install.sh. Risolve il chicken-egg del repo privato (non
# clonabile senza credenziali) senza esporre il PAT in argv o in .git/config.
#
# Usage:
#   FIGARO_REGISTRY_PAT=ghp_xxx  bash bootstrap.sh [<tag>] [<dest-dir>]
#   bash bootstrap.sh [<tag>] [<dest-dir>]        # chiede il PAT in modo interattivo
#
#   <tag>       tag immutabile del manifest (es. v0.1.0). Default: "latest"
#               → risolto via GitHub Releases API del repo manifest.
#   <dest-dir>  cartella di destinazione del clone. Default: figaro-secure-gateway
#
# Override via env: FIGARO_MANIFEST_REPO, FIGARO_REGISTRY_USER, REGISTRY_API_HOST,
#                   REGISTRY_GIT_HOST, FIGARO_BOOTSTRAP_NO_INSTALL=1 (solo provisioning).
#
# Prerequisiti: git, curl, Docker (con Compose v2). install.sh verifica il resto.

set -euo pipefail

# ── Config (override via env) ─────────────────────────────────────────────────
MANIFEST_REPO="${FIGARO_MANIFEST_REPO:-figarolab/figaro-gateway-deploy}"
REGISTRY_USER="${FIGARO_REGISTRY_USER:-figaro-deploy-bot}"
API_HOST="${REGISTRY_API_HOST:-api.github.com}"
GIT_HOST="${REGISTRY_GIT_HOST:-github.com}"

TAG="${1:-latest}"
DEST="${2:-figaro-secure-gateway}"

# ── Terminal colours ──────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

step() { echo -e "\n${CYAN}${BOLD}▸ $*${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $*"; }
info() { echo -e "  ${YELLOW}→${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; exit 1; }

command -v git  >/dev/null 2>&1 || fail "git non trovato — installalo prima di continuare (es. sudo apt-get install -y git)."
command -v curl >/dev/null 2>&1 || fail "curl non trovato — installalo prima di continuare (es. sudo apt-get install -y curl)."

# ── Intro ─────────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}Figaro Secure Gateway — bootstrap${RESET}"
echo    "  Questo script prepara una nuova installazione in 3 passi:"
echo -e "    ${CYAN}1.${RESET} scarica la configurazione ufficiale (manifest) dal repository del vendor"
echo -e "    ${CYAN}2.${RESET} salva in modo sicuro le credenziali del registry in config/registry.env (0640)"
echo -e "    ${CYAN}3.${RESET} avvia l'installer interattivo install.sh"
echo    "  Niente viene installato finché non rispondi alle domande dell'installer."

# ── PAT del registry ──────────────────────────────────────────────────────────
step "Credenziali registry"
info "Serve un Personal Access Token (PAT) GitHub con scope ${BOLD}read:packages${RESET} + ${BOLD}repo${RESET}."
info "Serve a scaricare le immagini Docker e la configurazione dal repo privato del vendor."
info "Il token non verrà mostrato a schermo né salvato in chiaro nei log."
if [[ -z "${FIGARO_REGISTRY_PAT:-}" ]]; then
  read -rsp "  Incolla il PAT e premi Invio: " FIGARO_REGISTRY_PAT
  echo
fi
[[ -n "${FIGARO_REGISTRY_PAT:-}" ]] || fail "PAT vuoto — impossibile autenticarsi al repo privato. Generane uno su https://github.com/settings/tokens (classic, scope read:packages + repo)."
export FIGARO_REGISTRY_PAT

# Il PAT viene passato a git via GIT_CONFIG_* (config a livello di processo): NON
# finisce in argv (quindi non in `ps`) né viene persistito nel .git/config del clone.
# Si usa Basic auth (username:token in base64) perché è il metodo che GitHub accetta
# per il git-over-HTTPS con un PAT — l'header Bearer vale per la REST API ma NON per
# il clone, e farebbe cadere git sul prompt interattivo "Username for ...".
# GIT_TERMINAL_PROMPT=0: se l'auth fallisce, git esce con errore invece di chiedere
# le credenziali a mano (così l'errore è chiaro e gestibile dallo script).
git_auth() {
  local basic
  basic="$(printf '%s' "x-access-token:${FIGARO_REGISTRY_PAT}" | base64 | tr -d '\n')"
  GIT_TERMINAL_PROMPT=0 \
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=http.extraHeader \
  GIT_CONFIG_VALUE_0="Authorization: Basic ${basic}" \
    git "$@"
}

# ── Risoluzione tag ───────────────────────────────────────────────────────────
if [[ "$TAG" == "latest" ]]; then
  step "Risoluzione ultimo tag del manifest"
  TAG="$(curl -fsSL \
    -H "Authorization: Bearer ${FIGARO_REGISTRY_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://${API_HOST}/repos/${MANIFEST_REPO}/releases/latest" \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')" \
    || fail "Releases API non raggiungibile o PAT non valido (repo ${MANIFEST_REPO})."
  [[ -n "$TAG" ]] || fail "Nessuna release trovata sul manifest — specifica un tag esplicito."
  ok "Ultimo tag: ${BOLD}${TAG}${RESET}"
fi

# Validazione tag (stesso pattern di figaro-updater) prima di usarlo nel checkout.
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "Tag non valido: '${TAG}'"

# ── Clone del manifest al tag ─────────────────────────────────────────────────
step "Scarico la configurazione (manifest ${MANIFEST_REPO}@${TAG}) → ${DEST}/"
if [[ -d "$DEST/.git" ]]; then
  # Ripresa di un bootstrap interrotto (Ctrl-C durante le domande di install.sh):
  # la destinazione è già il clone del manifest, la riusiamo al tag richiesto invece
  # di abortire. `.env` e config/ sono gitignored: il checkout non li tocca.
  info "Destinazione già presente — riprendo il clone esistente al tag ${TAG}"
  # Da qui in poi si esegue codice preso da questa directory (exec install.sh): il
  # riuso è ammesso SOLO se è davvero il clone del manifest del vendor e se il
  # worktree è pulito. Altrimenti si eseguirebbero file di provenienza ignota o
  # localmente modificati.
  ACTUAL_ORIGIN="$(git -C "$DEST" remote get-url origin 2>/dev/null || true)"
  [[ "${ACTUAL_ORIGIN%.git}" == "https://${GIT_HOST}/${MANIFEST_REPO}" ]] \
    || fail "'${DEST}' è un repo git ma il suo origin non è il manifest del vendor:
       atteso: https://${GIT_HOST}/${MANIFEST_REPO}.git
       trovato: ${ACTUAL_ORIGIN:-<nessun origin>}
     Rimuovila o passa un'altra <dest-dir> come secondo argomento."
  [[ -z "$(git -C "$DEST" status --porcelain --untracked-files=no)" ]] \
    || fail "'${DEST}' ha modifiche locali ai file tracciati: non la riuso, il
     checkout al tag ne eseguirebbe una versione alterata. Spostala e rilancia."
  # --detach + refs/tags/: nessuna ambiguità con un branch omonimo, stato = esattamente il tag.
  if ! ( cd "$DEST" \
         && git_auth fetch --force --depth 1 origin "refs/tags/${TAG}:refs/tags/${TAG}" \
         && git checkout --detach "refs/tags/${TAG}" ); then
    fail "Impossibile allineare il clone esistente al tag '${TAG}'.
     Verifica il PAT e la connettività, oppure passa un'altra <dest-dir>."
  fi
  ok "Configurazione allineata (tag ${TAG})"
else
  [[ -e "$DEST" ]] && fail "La destinazione '${DEST}' esiste già e non è un clone del manifest — rimuovila o passa un'altra <dest-dir> come secondo argomento."
  info "Clone in corso, può richiedere qualche secondo…"
  if ! git_auth clone --branch "$TAG" --depth 1 \
       "https://${GIT_HOST}/${MANIFEST_REPO}.git" "$DEST"; then
    fail "Clone del manifest fallito. Possibili cause:
       • il PAT non ha lo scope 'repo' (lettura del repo privato ${MANIFEST_REPO});
       • il tag '${TAG}' non esiste su quel repo;
       • problemi di rete verso ${GIT_HOST}.
     Verifica/rigenera il token su https://github.com/settings/tokens e riprova."
  fi
  ok "Configurazione scaricata (tag ${TAG})"
fi

cd "$DEST"

# ── Seed config/registry.env (0640) ───────────────────────────────────────────
step "Provisioning config/registry.env"
# 0750: registry.env è un env_file letto da `docker compose` anche quando
# l'updater (root ma cap_drop:[ALL], no DAC_OVERRIDE) esegue `compose up` durante
# un update registry → deve poterlo leggere via il gruppo host (FIGARO_HOST_GID,
# = gruppo primario di chi installa). 0700/0600 lo bloccherebbero (vedi #62).
install -d -m 750 config
# umask in subshell: evita che la maschera sui file appena creati "perda"
# l'execute bit sulle directory create da install.sh (es. certs/) dopo l'exec.
( umask 137
  printf 'FIGARO_REGISTRY_USER=%s\nFIGARO_REGISTRY_PAT=%s\n' \
    "$REGISTRY_USER" "$FIGARO_REGISTRY_PAT" > config/registry.env )
chmod 640 config/registry.env
ok "config/registry.env scritto (0640 — owner rw, gruppo updater r) — gitignored"

# ── Install ───────────────────────────────────────────────────────────────────
if [[ "${FIGARO_BOOTSTRAP_NO_INSTALL:-}" == "1" ]]; then
  echo ""
  ok "Provisioning completato. Avvia l'installazione con:"
  echo -e "     ${BOLD}cd ${DEST} && bash install.sh${RESET}"
  exit 0
fi

step "Avvio install.sh"
exec bash install.sh
