#!/usr/bin/env bash
#
# Synchronise les mods server-side vers le pod Minecraft.
#
# Copie la sélection de mods (contenu + worldgen + libs + optim + JEI) depuis
# l'instance PrismLauncher locale vers /data/mods dans le pod, puis redémarre.
#
# Usage:
#   ./sync-mods.sh              # staging + copie + restart
#   ./sync-mods.sh --no-clean   # ne vide pas /data/mods avant de copier
#   ./sync-mods.sh --no-restart # copie sans redémarrer le deployment
#   ./sync-mods.sh --dry-run    # montre seulement ce qui serait copié
#
# Prérequis : kubectl configuré sur le bon cluster, instance Prism présente.

set -euo pipefail

NAMESPACE="minecraft"
DEPLOYMENT="minecraft"
SRC="${MC_MODS_SRC:-/Users/alex/Library/Application Support/PrismLauncher/instances/Version 26.1.2/minecraft/mods}"
STAGE="/tmp/mc-server-mods"

CLEAN=1
RESTART=1
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --no-clean)   CLEAN=0 ;;
    --no-restart) RESTART=0 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Argument inconnu : $arg" >&2; exit 1 ;;
  esac
done

# Mods nécessaires côté serveur : contenu + worldgen + libs + optim server-safe + JEI.
# JEI est listé ici (et pas seulement côté client) car depuis MC 1.21.2 les recettes
# sont calculées côté serveur : sans JEI server-side, l'affichage des crafts est cassé.
MODS=(
  "FarmersDelight-*.jar"
  "Terralith_*.jar"
  "YungsBetterCaves-*.jar"
  "YungsBetterMineshafts-*.jar"
  "friendsandfoes-*.jar"
  "MutantMonsters-*.jar"
  "collective-*.jar"
  "treeharvester-*.jar"
  "fabric-api-*.jar"
  "fabric-language-kotlin-*.jar"
  "YungsApi-*.jar"
  "lithostitched-*.jar"
  "ResourcefulLib-*.jar"
  "ForgeConfigAPIPort-*.jar"
  "PuzzlesLib-*.jar"
  "ConfigManager-*.jar"
  "cloth-config-*.jar"
  "lithium-fabric-*.jar"
  "ferritecore-*.jar"
  "debugify-*.jar"
  "NoChatReports-*.jar"
  "jei-*.jar"
)

if [[ ! -d "$SRC" ]]; then
  echo "ERREUR : dossier source introuvable : $SRC" >&2
  echo "  (surcharge avec la variable d'env MC_MODS_SRC si besoin)" >&2
  exit 1
fi

echo "==> Staging des mods dans $STAGE"
rm -rf "$STAGE" && mkdir -p "$STAGE"

missing=0
for pattern in "${MODS[@]}"; do
  # nullglob pour qu'un motif sans correspondance ne reste pas littéral
  shopt -s nullglob
  matches=("$SRC"/$pattern)
  shopt -u nullglob
  if [[ ${#matches[@]} -gt 0 ]]; then
    cp "${matches[@]}" "$STAGE"/
    printf 'ok        %s\n' "$pattern"
  else
    printf 'MANQUANT  %s\n' "$pattern"
    missing=1
  fi
done

echo "==> Contenu du staging :"
ls -1 "$STAGE"

if [[ $missing -eq 1 ]]; then
  echo "ATTENTION : au moins un mod est manquant (voir MANQUANT ci-dessus)." >&2
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "==> --dry-run : on s'arrête là, rien n'est poussé."
  exit 0
fi

POD=$(kubectl -n "$NAMESPACE" get pod -l app="$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}')
echo "==> Pod cible : $POD"

if [[ $CLEAN -eq 1 ]]; then
  echo "==> Nettoyage de /data/mods côté pod"
  kubectl -n "$NAMESPACE" exec "$POD" -- sh -c 'rm -f /data/mods/*.jar'
fi

echo "==> Copie vers $POD:/data/mods (le /. évite mods/mods/)"
kubectl -n "$NAMESPACE" cp "$STAGE"/. "$POD":/data/mods

if [[ $RESTART -eq 1 ]]; then
  echo "==> Redémarrage du deployment"
  kubectl -n "$NAMESPACE" rollout restart deployment/"$DEPLOYMENT"
  echo "==> Suis le démarrage avec :"
  echo "    kubectl -n $NAMESPACE logs -f deploy/$DEPLOYMENT"
else
  echo "==> --no-restart : pense à redémarrer pour charger les nouveaux mods."
fi

echo "==> Terminé."
