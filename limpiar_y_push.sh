#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Script: limpiar_y_push.sh
# Objetivo:
#   - Clonar limpio desde GitHub
#   - Copiar código de un repo local existente (excluyendo data/)
#   - Asegurar .gitignore para DB/respaldos
#   - Commit limpio
#   - Push forzado a la rama main (o la que indiques)
#
# Uso:
#   ./limpiar_y_push.sh \
#     --origen "https://github.com/Thundernet-INV/kuma-agregator.git" \
#     --fuente "/opt/kuma-central/kuma-aggregator" \
#     --rama "main" \
#     [--dest "~/repo-limpio"] \
#     [--dry-run]
#
# Requisitos:
#   - git, rsync
#   - Acceso de push al remoto
# ------------------------------------------------------------

ORIGEN=""
FUENTE=""
RAMA="main"
DEST="${HOME}/repo-limpio"
DRY_RUN=0

# Excluye por defecto artefactos pesados de data/
EXCLUDES=(
  "data/"
  "*.db"
  "*.db.backup*"
)

print_help() {
  sed -n '1,70p' "$0" | sed 's/^# \{0,1\}//'
}

log() { echo -e "[INFO] $*"; }
warn() { echo -e "[ADVERTENCIA] $*" >&2; }
err() { echo -e "[ERROR] $*" >&2; exit 1; }

# Parseo de argumentos
while [[ $# -gt 0 ]]; do
  case "$1" in
    --origen)
      ORIGEN="${2:-}"; shift 2;;
    --fuente)
      FUENTE="${2:-}"; shift 2;;
    --rama)
      RAMA="${2:-}"; shift 2;;
    --dest)
      DEST="${2:-}"; shift 2;;
    --dry-run)
      DRY_RUN=1; shift;;
    -h|--help)
      print_help; exit 0;;
    *)
      err "Argumento no reconocido: $1. Usa --help.";;
  esac
done

[[ -z "$ORIGEN" ]] && err "Debes indicar --origen (URL del repo remoto)."
[[ -z "$FUENTE" ]] && err "Debes indicar --fuente (ruta del repo local existente)."
[[ -d "$FUENTE/.git" ]] || warn "La fuente no parece ser un repo Git. Se copiarán archivos igualmente."
command -v git >/dev/null 2>&1 || err "git no está instalado."
command -v rsync >/dev/null 2>&1 || err "rsync no está instalado."

log "Parámetros:"
log "  Remoto: $ORIGEN"
log "  Fuente local: $FUENTE"
log "  Rama: $RAMA"
log "  Destino limpio: $DEST"
[[ $DRY_RUN -eq 1 ]] && warn "MODO SIMULACIÓN (--dry-run): no se harán cambios permanentes."

# Construye flags de rsync con exclusiones
RSYNC_EXCLUDES=()
for patt in "${EXCLUDES[@]}"; do
  RSYNC_EXCLUDES+=(--exclude "$patt")
done

# Paso 1: Preparar directorio destino
if [[ -e "$DEST" ]]; then
  warn "El destino $DEST ya existe."
  if [[ $DRY_RUN -eq 0 ]]; then
    read -r -p "¿Deseas borrarlo para recrearlo? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
      rm -rf "$DEST"
    else
      err "Cancela o cambia --dest para continuar."
    fi
  else
    log "(dry-run) Se omite borrado de $DEST"
  fi
fi

# Paso 2: Clonar limpio desde remoto
if [[ $DRY_RUN -eq 0 ]]; then
  log "Clonando $ORIGEN -> $DEST ..."
  git clone "$ORIGEN" "$DEST"
else
  log "(dry-run) git clone $ORIGEN $DEST"
fi

# Paso 3: Verificar/crear rama
if [[ $DRY_RUN -eq 0 ]]; then
  cd "$DEST"
  # Obtén rama por defecto si no existe la indicada
  if ! git rev-parse --verify "$RAMA" >/dev/null 2>&1; then
    log "La rama $RAMA no existe localmente. Usando la rama por defecto del remoto."
    DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
    if [[ -n "$DEFAULT_BRANCH" && "$DEFAULT_BRANCH" != "$RAMA" ]]; then
      log "Cambiando a rama por defecto: $DEFAULT_BRANCH"
      git checkout -B "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH"
      RAMA="$DEFAULT_BRANCH"
    else
      log "Creando rama $RAMA desde vacío."
      git checkout -B "$RAMA"
    fi
  else
    git checkout "$RAMA"
  fi
else
  log "(dry-run) Comprobar/crear rama $RAMA"
fi

# Paso 4: Copiar contenido desde la fuente, excluyendo artefactos
if [[ $DRY_RUN -eq 0 ]]; then
  log "Copiando archivos desde $FUENTE (excluyendo: ${EXCLUDES[*]}) ..."
  rsync -av "${RSYNC_EXCLUDES[@]}" "$FUENTE"/ "$DEST"/
else
  log "(dry-run) rsync -av ${RSYNC_EXCLUDES[*]} $FUENTE/ $DEST/"
fi

# Paso 5: Asegurar .gitignore para DB/respaldos
GITIGNORE_LINES=(
  "data/*.db.backup*"
  "data/*.db"
)
if [[ $DRY_RUN -eq 0 ]]; then
  for line in "${GITIGNORE_LINES[@]}"; do
    grep -qxF "$line" .gitignore 2>/dev/null || echo "$line" >> .gitignore
  done
else
  log "(dry-run) Añadir a .gitignore: ${GITIGNORE_LINES[*]}"
fi

# Paso 6: Agregar y commit
if [[ $DRY_RUN -eq 0 ]]; then
  git add .
  if git diff --cached --quiet; then
    warn "No hay cambios para commitear. ¿Quizá ya está limpio?"
  else
    git commit -m "Commit limpio: sin archivos de base de datos/respaldos pesados"
  fi
else
  log "(dry-run) git add . && git commit ..."
fi

# Paso 7: Push forzado con seguridad (--force-with-lease)
if [[ $DRY_RUN -eq 0 ]]; then
  log "Haciendo push forzado a $RAMA en $ORIGEN ..."
  git push --force-with-lease origin "$RAMA"
  log "✅ Push completado."
else
  log "(dry-run) git push --force-with-lease origin $RAMA"
fi

log "Proceso finalizado."
