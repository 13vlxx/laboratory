# Kubernetes Labo — Documentation

Ce projet contient les manifests Kubernetes pour déployer des services sur un cluster k3s.  
Traefik est utilisé comme ingress controller (inclus par défaut dans k3s) et cert-manager gère les certificats TLS Let's Encrypt.

---

## Structure du projet

```
k3s/
├── namespace.yaml           ← Tous les namespaces du cluster
├── cert-manager/
│   └── cluster-issuer.yaml  ← Configuration Let's Encrypt
└── n8n/
    ├── deployment.yaml      ← Le pod n8n
    ├── service.yaml         ← Exposition interne du pod
    ├── ingress.yaml         ← Exposition publique via Traefik
    └── pvc.yaml             ← Volume de données persistant
```

---

## Concepts de base

### Namespace

Un namespace est un espace d'isolation logique dans Kubernetes. Deux ressources avec le même nom dans des namespaces différents ne se chevauchent pas. C'est l'équivalent d'un dossier pour organiser et isoler les ressources du cluster.

Tous les namespaces sont centralisés dans `k3s/namespace.yaml` :

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: alex-n8n   # nom unique du namespace
```

> Ajouter un nouveau service = ajouter un bloc dans ce fichier.

---

### Deployment

Un Deployment décrit **comment faire tourner un ou plusieurs pods** (conteneurs). Il gère le cycle de vie : démarrage, redémarrage en cas de crash, mise à jour de l'image, etc.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n              # nom du deployment
  namespace: alex-n8n    # namespace dans lequel il vit
  labels:
    app: n8n             # label pour identifier ce deployment

spec:
  replicas: 1            # nombre de pods à faire tourner simultanément
  selector:
    matchLabels:
      app: n8n           # doit correspondre aux labels du template ci-dessous

  template:              # modèle du pod créé par ce deployment
    metadata:
      labels:
        app: n8n         # label du pod, utilisé par le Service pour le trouver

    spec:
      securityContext:
        fsGroup: 1000    # groupe propriétaire des fichiers montés sur le volume
        runAsUser: 1000  # uid avec lequel le processus tourne dans le conteneur
        runAsGroup: 1000 # gid avec lequel le processus tourne dans le conteneur
                         # → nécessaire car n8n tourne avec l'user "node" (uid 1000)
                         #   et doit pouvoir écrire dans /home/node/.n8n

      containers:
        - name: n8n               # nom du conteneur (informatif)
          image: n8nio/n8n:latest # image Docker à utiliser

          ports:
            - containerPort: 5678 # port sur lequel l'application écoute dans le conteneur

          env:
            - name: N8N_HOST
              value: "0.0.0.0"              # écoute sur toutes les interfaces réseau du pod
            - name: N8N_PORT
              value: "5678"                 # port interne de n8n
            - name: N8N_PROTOCOL
              value: "http"                 # protocole interne (http, Traefik gère le HTTPS)
            - name: GENERIC_TIMEZONE
              value: "Europe/Paris"         # timezone pour les crons et logs
            - name: N8N_EDITOR_BASE_URL
              value: "https://n8n.labo.vlxx.fr"  # URL publique de l'interface n8n
            - name: WEBHOOK_URL
              value: "https://n8n.labo.vlxx.fr"  # URL de base pour les webhooks n8n
                                                  # sans ça, n8n génère des URLs incorrectes

          volumeMounts:
            - name: n8n-data            # nom du volume à monter (doit correspondre à volumes[])
              mountPath: /home/node/.n8n # chemin dans le conteneur où le volume est monté
                                         # c'est là que n8n stocke sa base SQLite et ses configs

          resources:
            requests:
              memory: "250Mi"  # mémoire minimum garantie au pod par le scheduler
              cpu: "100m"      # CPU minimum garanti (100m = 0.1 core)
            limits:
              memory: "512Mi"  # mémoire maximum autorisée avant que le pod soit tué (OOMKill)
              cpu: "500m"      # CPU maximum autorisé (500m = 0.5 core)

      volumes:
        - name: n8n-data                 # nom du volume (référencé dans volumeMounts)
          persistentVolumeClaim:
            claimName: n8n-pvc           # nom du PVC à utiliser (défini dans pvc.yaml)
```

> `requests` = ce que Kubernetes réserve pour planifier le pod sur un nœud.  
> `limits` = le plafond que le pod ne peut pas dépasser.

---

### PersistentVolumeClaim (PVC)

Un PVC est une **demande de stockage persistant**. Sans PVC, toutes les données d'un pod sont perdues à son redémarrage. Le PVC survit aux redémarrages et même à la suppression du pod.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: n8n-pvc        # nom du PVC, référencé dans le Deployment
  namespace: alex-n8n

spec:
  accessModes:
    - ReadWriteOnce    # le volume peut être monté en lecture/écriture par un seul pod à la fois
                       # autres valeurs possibles :
                       #   ReadOnlyMany  → plusieurs pods peuvent lire simultanément
                       #   ReadWriteMany → plusieurs pods peuvent lire/écrire simultanément
  resources:
    requests:
      storage: 5Gi     # taille du volume demandé
```

> Pour n8n qui utilise SQLite, 5Gi est largement suffisant pour un usage personnel.  
> Pour une base de données volumineuse, augmenter cette valeur en conséquence.

---

### Service

Un Service expose un pod **à l'intérieur du cluster**. Sans Service, les pods ne sont pas accessibles par les autres ressources Kubernetes (ni par l'Ingress).

Le Service fait aussi office de load balancer interne si `replicas > 1`.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: n8n          # nom du service, référencé dans l'Ingress
  namespace: alex-n8n

spec:
  selector:
    app: n8n         # cible les pods qui ont le label app=n8n
                     # doit correspondre aux labels du Deployment

  ports:
    - protocol: TCP
      port: 80         # port exposé par le Service à l'intérieur du cluster
      targetPort: 5678 # port du conteneur vers lequel le trafic est redirigé

  type: ClusterIP      # type du service :
                       #   ClusterIP   → accessible uniquement dans le cluster (défaut)
                       #   NodePort    → expose un port sur chaque nœud du cluster
                       #   LoadBalancer → crée un load balancer externe (cloud)
```

> Le flux réseau est : `Ingress → Service (port 80) → Pod (port 5678)`  
> Utiliser le port 80 sur le Service est une convention propre pour ne pas exposer
> les ports applicatifs dans la configuration réseau du cluster.

---

### Ingress

Un Ingress définit les **règles de routage HTTP/HTTPS depuis l'extérieur** vers les Services internes. C'est Traefik qui lit ces règles et route le trafic en conséquence.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: n8n
  namespace: alex-n8n
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    # → indique à cert-manager quel ClusterIssuer utiliser pour générer le certificat TLS

    traefik.ingress.kubernetes.io/router.entrypoints: "websecure"
    # → Traefik doit écouter sur l'entrypoint "websecure" (port 443)

    traefik.ingress.kubernetes.io/router.tls: "true"
    # → active le TLS sur cette route Traefik

spec:
  ingressClassName: traefik  # désigne Traefik comme ingress controller à utiliser

  tls:
    - hosts:
        - n8n.labo.vlxx.fr   # domaine pour lequel le certificat TLS est généré
      secretName: n8n-tls    # nom du Secret Kubernetes où cert-manager stocke le certificat

  rules:
    - host: n8n.labo.vlxx.fr  # domaine entrant
      http:
        paths:
          - path: /           # préfixe de l'URL (/ = tout le trafic)
            pathType: Prefix
            backend:
              service:
                name: n8n     # nom du Service vers lequel router le trafic
                port:
                  number: 80  # port du Service cible
```

> Le flux complet : `Internet (443) → Traefik → Service (80) → Pod (5678)`  
> cert-manager génère et renouvelle automatiquement le certificat Let's Encrypt
> dès que le DNS pointe vers le serveur.

---

## cert-manager

cert-manager est un contrôleur Kubernetes qui automatise la gestion des certificats TLS.  
Il surveille les ressources `Ingress` et génère automatiquement des certificats Let's Encrypt.

### ClusterIssuer

Un ClusterIssuer est la configuration globale de l'autorité de certification. Contrairement à un `Issuer` (namespaced), un `ClusterIssuer` est disponible pour tous les namespaces du cluster.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod   # nom référencé dans les annotations des Ingress

spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    # → URL de l'API ACME de Let's Encrypt (production)
    # → pour les tests, utiliser : https://acme-staging-v02.api.letsencrypt.org/directory

    email: alex@vlxx.fr
    # → email pour les notifications d'expiration de Let's Encrypt

    privateKeySecretRef:
      name: letsencrypt-prod
      # → Secret Kubernetes où est stockée la clé privée du compte ACME

    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
            # → méthode de validation HTTP-01 : Let's Encrypt appelle une URL temporaire
            #   sur le domaine pour prouver que tu en es propriétaire
            #   Traefik doit être accessible depuis Internet sur le port 80 pour que ça fonctionne
```

### Installation

cert-manager ne peut pas s'installer via de simples manifests car il nécessite ses CRDs en premier :

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --namespace cert-manager --for=condition=ready pod --selector=app.kubernetes.io/instance=cert-manager --timeout=120s
kubectl apply -f k3s/cert-manager/
```

---

## Déploiement

### Prérequis

- Un cluster k3s avec Traefik activé (défaut)
- cert-manager installé (voir ci-dessus)
- Un enregistrement DNS `A` pointant vers l'IP du serveur

### Commandes

```bash
# Appliquer les namespaces
kubectl apply -f k3s/namespace.yaml

# Appliquer le ClusterIssuer
kubectl apply -f k3s/cert-manager/

# Déployer n8n
kubectl apply -f k3s/n8n/

# Vérifier que le pod tourne
kubectl get pods -n alex-n8n

# Suivre les logs
kubectl logs -f deployment/n8n -n alex-n8n
```

### En local avec k3d

```bash
# Créer le cluster local
k3d cluster create labo --port "80:80@loadbalancer" --port "443:443@loadbalancer"

# Installer cert-manager + déployer
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --namespace cert-manager --for=condition=ready pod --selector=app.kubernetes.io/instance=cert-manager --timeout=120s
kubectl apply -f k3s/namespace.yaml
kubectl apply -f k3s/cert-manager/
kubectl apply -f k3s/n8n/

# Accéder à n8n en local
kubectl port-forward svc/n8n 5678:80 -n alex-n8n
# → http://localhost:5678
```

---

## Ajouter un nouveau service

1. Créer un dossier `k3s/<service>/`
2. Y ajouter les fichiers nécessaires :
   - `deployment.yaml` — toujours nécessaire
   - `service.yaml` — toujours nécessaire
   - `pvc.yaml` — si le service a besoin de persister des données
   - `ingress.yaml` — si le service doit être accessible depuis l'extérieur
3. Ajouter le namespace dans `k3s/namespace.yaml`
4. Appliquer : `kubectl apply -f k3s/<service>/`
