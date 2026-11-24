# Démo Azure AI Gateway

Démo technique du **nouveau `Microsoft.ApiManagement/aigateways`**, sans service APIM classique ni policies XML. Deux modèles Azure réels derrière des alias stables, deux identités Entra A/B, routage pondéré 80/20 ou conditionnel par identité, failover, limites de tokens et de coût, télémétrie native et Azure Monitor Workbook.

**Architecture : un alias fixe par scénario**, déclaré en Bicep. Pendant la démo, seule la valeur `model` de l'appel change ; aucune route ni stratégie n'est réécrite. Le diagramme est entièrement vidé au démarrage. La limite de coût reste désactivée (`price_missing=true`). Pour une nouvelle cible, aucune région, capacité ou disponibilité de modèle n'est présumée.

Le scénario **Identité de l’appelant · B → Backend 2** appelle `scenario-identity`. Sa condition CEL utilise l'identité Entra validée, pas un header libre. La qualification précédente sur alias reconfiguré a prouvé A 5/5 sur Backend 1, B 5/5 sur Backend 2 et l'absence de bascule de B sous panne ; elle ne remplace pas la recette de cette nouvelle architecture.

La recette HTTPS des alias fixes a confirmé : référence A/B 2/2, pondération observée 8/10–2/10, quatre bascules natives après une première tentative 404 sur le fournisseur dédié, A refusée en minute/heure pendant que B continue, identité A 5/5 Backend 1 et B 5/5 Backend 2. Les preuves et la distinction entre première vérification et relecture après ingestion sont décrites dans le guide.

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

Les scripts ciblent explicitement une souscription et un groupe `rg-aigw-demo-*` marqué pour cette gateway. Au plus dix appels séquentiels par scénario, sans retry client, corrélation W3C, sans conservation des prompts, réponses ou jetons. Chaque stratégie de tokens est propre à son alias, avec un compteur par identité authentifiée ; ce n'est pas un budget global partagé entre scénarios. Le runner vérifie que `demo-chat` et son ETag sont inchangés.

Le failover utilise un **fournisseur de laboratoire dédié en panne permanente**, sans toucher aux modèles des autres alias. Il ne démontre ni récupération ni panne régionale. Stop et « Vérifier les modèles fixes » ne remettent pas les compteurs Azure à zéro. Le coût affiché reste une estimation, pas une facture ni un plafond financier strict.

Le déploiement utilise des endpoints publics ; les modèles Foundry désactivent l'authentification par clé. `GlobalStandard` ne garantit pas la résidence régionale. Les ressources et leur télémétrie peuvent être facturées hors trafic : nettoyer le groupe dédié après la démo.

```powershell
.\scripts\reset-demo.ps1 -ConfigPath .\config\demo.local.json
.\scripts\cleanup.ps1 -ConfigPath .\config\demo.local.json -WhatIf
.\scripts\cleanup.ps1 -ConfigPath .\config\demo.local.json
```
