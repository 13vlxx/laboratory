# Minecraft Server (Fabric)

Serveur Minecraft Fabric tournant sur k3s, image [`itzg/minecraft-server`](https://hub.docker.com/r/itzg/minecraft-server).

## Vue d'ensemble

| Ressource | Valeur |
|---|---|
| Namespace | `minecraft` |
| Deployment | `minecraft` |
| PVC | `minecraft-pvc` (storageClass `local-path`, données sur le nœud) |
| Service | `minecraft` (LoadBalancer, port `25565` TCP) |
| Données | `/data` dans le pod |
| Mods | `/data/mods` |

Le PVC utilise `local-path`, donc les fichiers vivent **directement sur le disque du nœud** sous
`/var/lib/rancher/k3s/storage/pvc-<uid>_minecraft_minecraft-pvc/`.

## Déployer / mettre à jour

```bash
kubectl apply -f k3s/namespace.yaml
kubectl apply -f k3s/minecraft/
```

Redémarrer le pod sans changer la config (ex. après avoir ajouté des mods) :

```bash
kubectl -n minecraft rollout restart deployment/minecraft
```

Suivre le démarrage (attendre `Done (X.XXs)!`) :

```bash
kubectl -n minecraft logs -f deploy/minecraft
```

## Quels mods côté serveur ?

On ne pousse sur le serveur **que** les mods server-side. Règle simple :

| Type de mod | Côté | Sur le serveur ? |
|---|---|---|
| Visuel / UI / contrôles (Sodium, Iris, Xaero, Jade, zoom, textures…) | **client** | ❌ non |
| Contenu / worldgen / gameplay (Terralith, YUNG's, Farmer's Delight, mobs…) | **both** | ✅ oui (même version que le client) |
| Optimisation serveur (Lithium, FerriteCore) | both | ✅ oui |
| Librairies/dépendances (Fabric API, Kotlin, Cloth Config, Resourceful Lib…) | both | ✅ oui |

Vérifie le badge **Client / Server / Both** sur la page Modrinth du mod en cas de doute.
Un mod « both » oublié côté serveur (ou en version différente) ⇒ kick **mod mismatch** à la connexion.

> ⚠️ **Cas JEI (et autres viewers de recettes).** Depuis **Minecraft 1.21.2**, les recettes sont
> calculées **côté serveur** et ne sont plus envoyées en entier au client : seul le livre de recettes
> vanilla fonctionne, mais JEI n'a pas les recettes de craft et n'affiche que ses catégories générées
> client-side (combustible, enclume…). Bien que JEI soit un mod « visuel », il faut donc l'installer
> **aussi côté serveur** (même version que le client) pour qu'il re-synchronise les recettes complètes.
> Symptôme typique : `R` sur un item ne montre pas l'établi alors que tout marche en solo.

## Ajouter des mods

> ⚠️ Les mods doivent correspondre à la version Fabric/Minecraft du serveur (`VERSION` dans le deployment).

### Méthode recommandée — le script `sync-mods.sh`

[`sync-mods.sh`](./sync-mods.sh) automatise tout : il copie la sélection de mods server-side depuis
l'instance PrismLauncher locale dans un dossier de staging, puis l'envoie dans `/data/mods` du pod
via `kubectl cp` et redémarre le deployment.

```bash
cd k3s/minecraft

./sync-mods.sh              # staging + clean /data/mods + copie + restart
./sync-mods.sh --dry-run    # montre ce qui serait copié, ne pousse rien
./sync-mods.sh --no-clean   # ajoute sans vider le dossier serveur d'abord
./sync-mods.sh --no-restart # copie sans redémarrer (utile pour batcher)
```

- **La liste des mods server-side vit en haut du script** (tableau `MODS`). Pour ajouter/retirer un
  mod côté serveur, édite cette liste — un seul endroit à maintenir.
- Chaque mod absent du dossier source est signalé `MANQUANT` (sans planter) et un avertissement final
  s'affiche. Pratique pour repérer un mod désactivé/supprimé côté client.
- Le chemin source par défaut pointe vers l'instance `Version 26.1.2`. Surcharge-le si besoin :
  ```bash
  MC_MODS_SRC="/chemin/vers/instance/.../mods" ./sync-mods.sh
  ```
- Le `kubectl cp` utilise un `/.` final pour copier le **contenu** du staging et éviter le piège
  `mods/mods/`.

Suis ensuite le démarrage (attendre `Done (X.XXs)!`) :

```bash
kubectl -n minecraft logs -f deploy/minecraft
```

> 💡 Côté client (instance Prism), tu gardes **tous** les mods, y compris les « both » du serveur.
> Et inversement : un mod « both » présent côté serveur (ex. `treeharvester`) doit aussi rester côté
> client, sinon risque de **mod mismatch**.

### Méthode alternative — scp vers le nœud distant

À utiliser si tu préfères passer par le filesystem du nœud. Les permissions du dossier du volume
appartiennent à root, donc on passe par `/tmp` puis `sudo mv`.

```bash
# 1. Chemin du volume sur le nœud
BASE=$(kubectl get pv $(kubectl -n minecraft get pvc minecraft-pvc -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.local.path}')

# 2. Envoie les .jar dans /tmp du nœud (remplace user@noeud)
cd "/Users/alex/Library/Application Support/PrismLauncher/instances/Version 26.1.2/minecraft"
scp ./mods/*.jar user@noeud:/tmp/

# 3. Sur le nœud : déplace dans mods/ avec sudo
ssh user@noeud "sudo mv /tmp/*.jar '$BASE'/mods/ && sudo ls -lh '$BASE'/mods"

# 4. Recharge le serveur
kubectl -n minecraft rollout restart deployment/minecraft
```

## Vérifier les mods

Présents sur le disque :

```bash
POD=$(kubectl -n minecraft get pod -l app=minecraft -o jsonpath='{.items[0].metadata.name}')
kubectl -n minecraft exec "$POD" -- ls -lh /data/mods
```

Réellement chargés par Fabric :

```bash
kubectl -n minecraft logs deploy/minecraft | grep -i "Loading.*mods"
```

### Corriger un mods/mods imbriqué

Si tu as copié `./mods` (sans `/.`) et que les jars se retrouvent dans `/data/mods/mods` :

```bash
BASE=$(kubectl get pv $(kubectl -n minecraft get pvc minecraft-pvc -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.local.path}')
ssh user@noeud "sudo mv '$BASE'/mods/mods/*.jar '$BASE'/mods/ && sudo rm -rf '$BASE'/mods/mods"
kubectl -n minecraft rollout restart deployment/minecraft
```

## Variables d'env utiles (deployment.yaml)

| Variable | Rôle |
|---|---|
| `TYPE` | `FABRIC` |
| `VERSION` | Version Minecraft (ex. `26.2`) — doit matcher les mods |
| `MEMORY` | Heap JVM (ex. `4G`) |
| `LEVEL` | Nom du dossier du monde actif dans `/data` — change-le pour basculer de monde |
| `MODE` | `survival` \| `creative` \| `adventure` \| `spectator` (uniquement à la création du monde) |
| `MOTD` | Texte affiché sous le serveur dans la liste multijoueur |
| `OPS` | Pseudos admins (droits de commande), séparés par des virgules |
| `ENABLE_WHITELIST` | `true` pour restreindre l'accès à la whitelist |
| `ENFORCE_WHITELIST` | `true` pour kick immédiatement les non-autorisés |
| `WHITELIST` | Pseudos autorisés, séparés par des virgules. Les `/whitelist add` en jeu sont conservés (merge par défaut) |
| `SEED` | Seed du monde (uniquement à la création) |

## Gérer les mondes

`LEVEL` désigne le monde chargé. Supprimer le dossier d'un monde puis redémarrer le régénère.

```bash
POD=$(kubectl -n minecraft get pod -l app=minecraft -o jsonpath='{.items[0].metadata.name}')

# Sauvegarde avant suppression si le monde a de la valeur
kubectl -n minecraft cp "$POD":/data/survival ./backup-survival

# Repartir à neuf sur le monde actif (LEVEL=survival)
kubectl -n minecraft exec "$POD" -- rm -rf /data/survival
kubectl -n minecraft rollout restart deployment/minecraft

# Supprimer un monde inutilisé (non chargé) — pas besoin de régénérer
kubectl -n minecraft exec "$POD" -- rm -rf /data/world
```

## Connexion

Le service est exposé en LoadBalancer sur le port `25565`. Les joueurs se connectent sur
`<IP-du-nœud>:25565` (ou un DNS A pointant vers cette IP).
