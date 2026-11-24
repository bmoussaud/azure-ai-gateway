# Démo Azure AI Gateway

Démo technique du **nouveau `Microsoft.ApiManagement/aigateways`**, sans service APIM classique ni policies XML. Deux modèles Azure réels derrière des alias stables, deux identités Entra A/B, routage pondéré 80/20 ou conditionnel par identité, failover, limites de tokens et de coût, télémétrie native et Azure Monitor Workbook.

**État : déployé et vérifié dans Azure : baseline A/B, routage 40/50–10/50, failover/récupération et limites de tokens minute/heure.** La limite de coût reste bloquée par le signal natif de tarification incomplète ; elle n'est pas certifiée. Pour une nouvelle cible, aucune région, capacité ou disponibilité de modèle n'est présumée.

Le scénario **Identité de l’appelant · B → Backend 2** est aussi déployé et prouvé par HTTPS et traces natives : A 5/5 sur Backend 1, B 5/5 sur Backend 2. Backend 2 indisponible : B échoue sans bascule, A continue. La condition CEL utilise l'identité Entra validée, pas un header libre ; elle s'applique à `demo-chat`, pas à toutes les routes autorisées.

Application Insights est activé sur le composant existant et lié au DCR natif reconnu par le portail. Une nouvelle baseline A/B a été vérifiée dans ses logs et traces natifs ; l'affichage visuel de la bannière du portail n'a pas été observé.

## Utilisation

PowerShell 7.4+, Azure CLI avec Bicep, droits de création et d'attribution RBAC et capacité de modèle vérifiée sont nécessaires. Utiliser deux identités applicatives existantes ou activer `provisionDemoCallers` pour créer des identités managées A/B dédiées.

```powershell
Copy-Item .\config\demo.example.json .\config\demo.local.json
# Renseigner les valeurs explicites et les prix vérifiés dans ce fichier ignoré par Git.
.\scripts\preflight.ps1 -ConfigPath .\config\demo.local.json -Offline
.\tests\local.tests.ps1

# Après autorisation de la cible : découverte, ARM validate et what-if sans création.
.\scripts\deploy.ps1 -ConfigPath .\config\demo.local.json
# Création explicite, uniquement après examen du what-if :
.\scripts\deploy.ps1 -ConfigPath .\config\demo.local.json -Apply
```

Le [guide opérateur](docs/demo-guide.md) décrit l'authentification A/B, les scénarios, les assertions natives, le reset et le nettoyage. La [matrice des contrats et limites](docs/capabilities.md) distingue les capacités documentées des comportements restant à vérifier dans Azure.

### Console HTTPS A/B

```powershell
.\scripts\deploy-console.ps1 -ConfigPath .\config\demo.local.json
```

La commande déploie une console Azure Container Apps avec les deux applications A/B et les boutons de scénarios. **Connexion Entra obligatoire, limitée à l'utilisateur opérateur et à l'identité managée d'acceptation**, sans consommation anonyme. La restriction IPv4 /32 du bootstrap n'est retirée qu'après vérification de cette protection native. Les identités et jetons d'inférence restent côté serveur. Les backends affichés proviennent des traces natives après ingestion ; le coût reste désactivé tant que sa tarification est incomplète. Le [guide](docs/demo-guide.md) détaille les droits de déploiement, la durée de validité du secret de connexion et le nettoyage.

## Garde-fous

Les scripts ciblent explicitement une souscription et un groupe `rg-aigw-demo-*` marqué pour cette gateway. Les requêtes sont séquentielles, bornées, sans retry client, avec corrélation W3C et sans conservation des prompts, réponses ou jetons d'accès. Les compteurs utilisent l'identité authentifiée, jamais un header client libre. La configuration est relue après modification et protégée par ETag.

Le failover utilise une **mauvaise route backend injectée pour le laboratoire**, pas une panne régionale simulée par une fonction native du produit. Le coût affiché est une estimation, pas une facture ni un plafond financier strict. Un prix manquant peut rendre la limite de coût permissive ; le runner refuse ce scénario sans preuve de tarification native complète.

Le déploiement utilise des endpoints publics ; les modèles Foundry désactivent l'authentification par clé. `GlobalStandard` ne garantit pas la résidence régionale. Les ressources et leur télémétrie peuvent être facturées hors trafic : nettoyer le groupe dédié après la démo.

```powershell
.\scripts\reset-demo.ps1 -ConfigPath .\config\demo.local.json
.\scripts\cleanup.ps1 -ConfigPath .\config\demo.local.json -WhatIf
.\scripts\cleanup.ps1 -ConfigPath .\config\demo.local.json
```
