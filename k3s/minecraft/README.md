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

## Ajouter des mods

> ⚠️ Les mods doivent correspondre à la version Fabric/Minecraft du serveur (`VERSION` dans le deployment).
> Pense à ne mettre côté serveur **que** les mods server-side (les mods purement client comme
> `xaerominimap` ou `jei` n'ont rien à faire ici).

### Méthode recommandée — `kubectl cp` (depuis ta machine, sans SSH)

Le `/.` à la fin copie le **contenu** du dossier et évite le piège `mods/mods/` :

```bash
POD=$(kubectl -n minecraft get pod -l app=minecraft -o jsonpath='{.items[0].metadata.name}')

cd "/Users/alex/Library/Application Support/PrismLauncher/instances/Perso/minecraft"

kubectl -n minecraft cp ./mods/. "$POD":/data/mods

kubectl -n minecraft rollout restart deployment/minecraft
```

### Méthode alternative — scp vers le nœud distant

À utiliser si tu préfères passer par le filesystem du nœud. Les permissions du dossier du volume
appartiennent à root, donc on passe par `/tmp` puis `sudo mv`.

```bash
# 1. Chemin du volume sur le nœud
BASE=$(kubectl get pv $(kubectl -n minecraft get pvc minecraft-pvc -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.local.path}')

# 2. Envoie les .jar dans /tmp du nœud (remplace user@noeud)
cd "/Users/alex/Library/Application Support/PrismLauncher/instances/Perso/minecraft"
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

## Connexion

Le service est exposé en LoadBalancer sur le port `25565`. Les joueurs se connectent sur
`<IP-du-nœud>:25565` (ou un DNS A pointant vers cette IP).
