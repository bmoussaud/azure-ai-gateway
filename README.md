# Démo Azure AI Foundry

Cette démo déploie deux projets Microsoft Foundry, `project-1` et `project-2`, chacun avec son propre déploiement `gpt-6-sol` (version `2026-09-22`). Chaque projet possède sa propre ressource Foundry : les déploiements de modèles sont en effet partagés entre les projets d'une même ressource.

## Prérequis

- Une souscription Azure et les droits de création de ressources Cognitive Services.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) avec Bicep (`az bicep install`).
- L'accès au modèle et un quota **Global Standard** suffisant pour deux déploiements dans la région choisie. Par défaut, chacun utilise une capacité de 10 milliers de tokens par minute. La disponibilité et le quota dépendent de la souscription et de la région.

Le déploiement et l'utilisation peuvent engendrer des coûts. `GlobalStandard` peut traiter les données hors de la région de la ressource. Cette démo active l'accès réseau public et désactive l'authentification par clé : utilisez Microsoft Entra ID et accordez les rôles nécessaires aux utilisateurs. Elle ne configure pas de réseau privé.

## Déploiement

Depuis la racine du dépôt :

```bash
az login
az account set --subscription "<subscription-id>"

LOCATION="eastus"
RESOURCE_GROUP="rg-foundry-demo"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file infra/main.bicep \
  --parameters location="$LOCATION"
```

Le résultat `projects` contient les identifiants des projets et des ressources Foundry, les endpoints et les noms de déploiement. Le nom des ressources Foundry est généré de manière stable à partir du groupe de ressources. Pour ajuster la capacité ou la version disponible dans votre souscription, ajoutez par exemple `modelCapacity=1 modelVersion=2026-09-22` aux paramètres. Le quota total nécessaire est la somme des capacités des deux déploiements.

Pour accéder aux modèles avec Entra ID, l'utilisateur doit disposer d'un rôle de plan de données adapté, par exemple **Cognitive Services OpenAI User**, sur chaque ressource Foundry ; les droits de déploiement ne le garantissent pas. L'attribution de rôles nécessite elle-même les autorisations appropriées.

Vérifiez les ressources et déploiements :

```bash
az deployment group show --resource-group "$RESOURCE_GROUP" --name main --query properties.outputs.projects.value
az cognitiveservices account list --resource-group "$RESOURCE_GROUP" --output table
```

## Nettoyage

Pour supprimer toutes les ressources de la démo, si le groupe leur est réservé :

```bash
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
```

Références : [modèle GPT-6 Sol](https://ai.azure.com/catalog/models/gpt-6-sol), [projets Foundry en Bicep](https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/2025-06-01/accounts/projects) et [planification Foundry](https://learn.microsoft.com/azure/foundry/concepts/planning).
