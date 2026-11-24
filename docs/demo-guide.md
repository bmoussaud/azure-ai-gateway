# Guide de démonstration

## Principe : choisir un modèle, pas reconfigurer la passerelle

Les alias, stratégies et conditions sont déployés une fois avec Bicep.
Pendant la présentation, l'application ne change que le champ `model` envoyé
à la même URL Chat Completions. Le runner et la console ne font aucune écriture
ARM, même au démarrage, après Stop ou après une erreur.

| Scénario | Alias appelé | Ce qu'on montre |
|---|---|---|
| Référence A/B | `demo-chat` | Deux appels, A puis B ; Backend 1 prioritaire. |
| Pondération 80/20 | `scenario-weighted-80-20` | Dix appels, priorités égales et poids 80/20. Les nombres observés ne promettent pas exactement 8/2. |
| Basculement | `scenario-failover` | Quatre appels A/B ; modèle de laboratoire `backend-fault/demo-unavailable` en priorité 0, Backend 2 en priorité 1, une tentative supplémentaire native. |
| Limite minute | `scenario-token-rate` | Stratégie fixe 256 tokens/minute par identité sur cet alias ; A reçoit un rejet natif 429, B continue. |
| Quota horaire | `scenario-token-quota` | Stratégie fixe 256 tokens/heure par identité sur cet alias ; A reçoit un rejet natif 403, B continue. |
| Identité de l'appelant | `scenario-identity` | Cinq A et cinq B : CEL exclut B de Backend 1 ; B ne peut sélectionner que Backend 2. |
| Vérifier les modèles fixes | Aucun appel d'inférence | Relire les six définitions ; aucune remise à zéro ni écriture. |
| Coût | Désactivé | `price_missing=true` interdit de certifier la limite monétaire, même avec des coûts estimés non nuls. |

`demo-alt` reste déployé et autorisé mais caché ; aucun scénario courant ne
l'appelle. A/B ont chacun Models User sur les sept alias, jamais sur les comptes
Foundry. Ce RBAC autorise un alias, pas un backend spécifique.

## Présenter la console

Utiliser l'URL HTTPS imprimée par `deploy-console.ps1`. Connexion Entra obligatoire,
limitée à l'utilisateur opérateur et à l'identité managée d'acceptation.
L'authentification native, son allowlist exacte et les protections Origin/CSRF
restent actives ; aucun endpoint anonyme ne consomme des tokens. Les jetons A/B
restent côté serveur. Les identités A/B ne peuvent pas opérer la console.

1. Choisir le scénario, puis **Start**. Dire : « Nous appelons le modèle affiché,
   déjà configuré dans Azure. Nous ne changeons aucune règle pendant la démo. »
2. Le diagramme précédent est entièrement effacé : routes, preuves, compteurs,
   cadenas, badges et états. Le journal décrit l'alias et sa configuration fixe.
   Les pointillés décrivent cette configuration, pas un backend réellement servi.
3. Les statuts HTTP, tokens et trace IDs arrivent immédiatement. Attendre
   **Vérifié** : seuls les backends joints aux traces Azure natives par trace ID
   produisent les traits verts et résultats de backend.
4. **Stop** laisse finir l'opération en cours, empêche les appels suivants et garde
   les réponses déjà reçues. Une exécution partielle n'est jamais certifiée.
   Il n'y a aucune configuration à restaurer.
5. Le contrôle final relit intégralement `demo-chat` et son ETag : ils doivent
   être identiques. Une différence bloque la certification, sans réparation cachée.

Au plus dix appels par scénario, un appel en vol, zéro retry client, au plus deux
secondes d'attente intentionnelle entre appels. Latence du modèle et ingestion
Application Insights sont séparées. La capacité réelle des deux déploiements
est lue avant le trafic ; une capacité insuffisante provoque un refus explicite.
La qualification dédiée utilise 40 RPM/40 000 TPM par backend.

**Rejouer** anime uniquement les événements enregistrés, sans trafic.
**Plein écran** facilite la projection. Un rafraîchissement ne déclenche pas
d'inférence. Les historiques sont bornés et éphémères : préserver les preuves
avant redémarrage. Une télémétrie absente ou retardée est inconnue, pas un succès.

### Identité : B vers Backend 2

Lire dans le journal la condition portée par Backend 1 :

```text
@cel(!(has(authorization.identity) && has(authorization.identity.id) &&
       authorization.identity.id == '<tenantId>:<objectIdB>'))
```

Le tenant et l'object ID validés sont normalisés en minuscules au déploiement.
Azure évalue les conditions avant priorité, poids et affinité, y compris après un
échec. Aucun header fourni par le client ne décide du backend.
Backend 2 n'a aucune condition. A conserve donc Backend 1 prioritaire.
Le cadenas est une règle configurée, jamais une preuve d'exécution.

Dire : « On peut segmenter par identité d'application vers un déploiement dédié,
un modèle ou un quota d'équipe. Ici, nous prouvons seulement la sélection des
deux backends du même modèle. » Les compteurs A/B sont par application, pas un
budget partagé de groupe Entra.

**Hard pin** : si Backend 2 tombe, B doit échouer sans repli vers Backend 1,
pendant que A peut continuer. Ce n'est pas une garantie de disponibilité, ni une
interdiction d'utiliser un autre alias déjà autorisé. Le contrôle négatif historique
est conservé dans `.demo\5a944b9d63a346c5acd1cd4d2d3698f2{,.verified}.json` :
B sain 200, B sous panne 404 avec une seule tentative, deux A 200 sur Backend 1.
Ce test antérieur modifiait temporairement un endpoint ; son ancien switch
`-IdentityBackendFault` est désormais refusé pour préserver les configurations fixes.

### Basculement permanent de laboratoire

Seul `scenario-failover` référence le fournisseur dédié `backend-fault` dont
l'adresse porte un préfixe volontairement invalide. Les deux fournisseurs réels
restent intacts. Le premier envoi doit échouer, puis la passerelle sélectionne
Backend 2 ; le client ne réessaie pas. La règle 404 est propre au laboratoire.
Pas d'exclusion persistante : chaque appel doit montrer deux tentatives natives.

Ne pas présenter cette panne permanente comme une panne régionale, une panne
réseau ou une démonstration de récupération. L'ancien scénario
exclusion/tous-backends-indisponibles/récupération n'est plus exécuté.

### Compteurs persistants

Les stratégies de tokens ont `scope: "resource"` et `counterKey: ["identity"]`.
Chaque alias a ses propres compteurs A/B. Changer d'alias change volontairement
de stratégie : **ce n'est pas une enveloppe globale anti-contournement**.
Une nouvelle exécution peut commencer avec A déjà épuisée.
Ni Start, ni Stop, ni « Vérifier » ne réinitialisent les compteurs ; attendre leur
renouvellement naturel. Un changement de fenêtre pendant le test peut rendre
l'assertion inconclusive : ne pas masquer cette erreur ou relancer automatiquement.

L'usage déjà admis peut dépasser 256 tokens ; il ne s'agit pas d'un plafond strict.
Le runner ajoute seulement à A des entrées synthétiques bornées (640 marqueurs
pour minute, 160 pour heure), B conservant le court prompt témoin.
Les jauges représentent l'usage des réponses observées, pas les compteurs internes.

## Déployer et vérifier

PowerShell 7.4+, Azure CLI/Bicep et droits de déploiement/RBAC sont nécessaires.
La cible doit être une souscription explicitement autorisée et un groupe dédié
`rg-aigw-demo-*` avec les marqueurs de propriété attendus. Ne pas changer le
contexte d'un CLI partagé. Aucune disponibilité région/modèle/SKU n'est présumée.
`GlobalStandard` ne garantit pas la résidence régionale.

```powershell
Copy-Item .\config\demo.example.json .\config\demo.local.json
# Renseigner la cible, le modèle, la capacité et des prix maximum vérifiés.
.\scripts\preflight.ps1 -ConfigPath .\config\demo.local.json -Offline
.\tests\local.tests.ps1
python -m unittest discover -s .\tests -p 'test_console*.py'
.\scripts\deploy.ps1 -ConfigPath .\config\demo.local.json
.\scripts\deploy.ps1 -ConfigPath .\config\demo.local.json -Apply
.\scripts\deploy-console.ps1 -ConfigPath .\config\demo.local.json
```

`deploy.ps1` fait préflight, compilation, ARM validate et what-if avant création.
Certaines attributions RBAC à ID dynamique peuvent être non analysables par
what-if ; ne pas appeler cela un no-op. Bicep est la source des alias/policies ;
les JSON versionnés sont chargés par Bicep et relus par les scripts.
`configure.ps1` et `reset-demo.ps1` sont maintenant des vérifications en lecture
seule, pas des commandes de mutation.

Le rôle opérateur console est désormais **lecture seule** sur la configuration
gateway ; il n'a ni IAM ni droit d'inférence. Les identités A/B font l'inférence.
La console possède aussi lecture du groupe et de la télémétrie et AcrPull sur son
registre dédié. Les images sont construites par ACR et déployées par digest.
Un déploiement met d'abord l'ancienne console en maintenance et refuse un job actif.

Easy Auth est amorcé derrière une IPv4 /32 ; cette restriction n'est retirée
qu'après relecture de l'auth Entra et de son allowlist exacte. Le secret de
connexion de 30 jours est un paramètre Bicep sécurisé, jamais un token navigateur
ni une variable de conteneur. Le script réutilise un secret courant ou le renouvelle
à deux jours de l'expiration. Le déployeur doit pouvoir créer et posséder
l'inscription Entra dédiée. Ses identifiants non secrets restent dans le JSON local
ignoré par Git. Ne jamais journaliser de jeton ou de secret.

### Recette HTTPS sans exposer de jeton

```powershell
az containerapp exec --subscription '<subscription-id>' --resource-group '<demo-group>' `
  --name '<gateway-name>-console' --command 'python3 /app/console/operate.py accept'
```

Le helper utilise en mémoire l'identité managée opérateur et appelle réellement
l'origine HTTPS publique. Il vérifie anonyme/non-autorisé/CSRF/concurrence, puis
les six scénarios et la vérification finale. Les preuves sans secrets sont écrites
dans `/tmp/console-acceptance.json`. Exiger `CONSOLE_ACCEPTANCE_VERIFIED` :
un code de sortie zéro du tunnel exec ne prouve pas le succès distant.
Ne pas exécuter une recette pendant une présentation.

Pour le CLI, fournir les tokens A/B via les variables d'environnement du processus
`DEMO_TEAM_A_TOKEN` et `DEMO_TEAM_B_TOKEN`, audience `https://ai.gateway.azure.com`.
Ne jamais les mettre dans des arguments, fichiers, captures ou logs.
L'ACI optionnel peut acquérir les identités dédiées sans secrets :

```powershell
.\scripts\run-with-managed-callers.ps1 -ConfigPath .\config\demo.local.json -Scenario baseline
.\scripts\run-scenario.ps1 -ConfigPath .\config\demo.local.json -Scenario identity-routing
.\scripts\verify-results.ps1 -ConfigPath .\config\demo.local.json -ResultsPath '.\.demo\<run-id>.json'
```

Arrêter explicitement l'ACI après usage. Les anciens switches d'alias alternatif
et de panne temporaire sont refusés ; tous les scénarios courants sont mono-alias.

## Application Insights et Workbook

L'intégration native est activée sur le composant workspace-based existant via
`AzureMonitorWorkspaceIngestionMode: Enabled` (API `2020-02-02-preview`).
Le composant publie son DCR et ses endpoints OTLP. La passerelle utilise
l'exporteur OpenTelemetry à identité managée, audience `https://monitor.azure.com/`,
sans capturer prompts/réponses.

Le lien composant/DCR a été vérifié par la requête Resource Graph équivalente à
celle du portail, et des requêtes A/B ont été retrouvées dans ses logs/traces
natifs. **La disparition visuelle de la bannière du portail n'a pas été observée.**
Les anciens DCR manuels sont conservés sans recevoir le nouveau trafic.

Exception IaC : le groupe de monitoring géré par Azure refuse les déploiements
imbriqués, mais autorise l'attribution directe de rôle. `deploy.ps1` vérifie le lien
exact composant/DCR et donne idempotemment Monitoring Metrics Publisher sur ce
DCR seulement (ARM `2022-04-01`), sans toucher à la deny assignment.

Le Workbook **AI Gateway - teams A/B** et `observability\requests.kql` utilisent
`OTelSpans`/`OTelLogs`, la composante Insights et le hostname exact.
Ils montrent succès/rejets, origine de stratégie, latence p50/p95, backend, tokens,
coût estimé et trace ID. Une attribution native `tokenLimit` est obligatoire pour
certifier un rejet de gouvernance ; le seul statut HTTP ne suffit pas.
Ingestion retardée de plusieurs minutes, rétention 30 jours et plafond LAW 1 Go/jour.
Aucune métrique de quota restant n'est inventée.

## Nettoyer

```powershell
.\scripts\reset-demo.ps1 -ConfigPath .\config\demo.local.json
.\scripts\cleanup.ps1 -ConfigPath .\config\demo.local.json -WhatIf
.\scripts\cleanup.ps1 -ConfigPath .\config\demo.local.json
Remove-Item Env:\DEMO_TEAM_A_TOKEN, Env:\DEMO_TEAM_B_TOKEN -ErrorAction SilentlyContinue
```

Le nettoyage vérifie les marqueurs et une allowlist exacte du groupe dédié,
y compris l'alerte Failure Anomalies exclusivement liée à son composant.
Ne jamais élargir la suppression à un groupe partagé ou au groupe monitoring
géré par Azure ; vérifier son cycle de vie après suppression du composant.
Les identités externes ne sont pas supprimées. Supprimer l'inscription Entra
console uniquement après vérification de son object ID, appId, nom et propriétaire
à partir des valeurs locales ; aucun delete par nom ambigu.

## Preuves et limites

### Recette réelle des alias fixes

Les sept alias et les quatorze attributions Models User A/B ont été relus après
déploiement. La campagne utilise réellement l'API HTTPS protégée et les identités
managées A/B, pas une simulation des réponses.

| Alias | Résultat HTTP et natif observé |
|---|---|
| `demo-chat` | A 1/1 et B 1/1 HTTP 200, Backend 1. |
| `scenario-weighted-80-20` | Dix HTTP 200 ; Backend 1 : 8, Backend 2 : 2. Ce petit échantillon ne certifie pas statistiquement les poids. |
| `scenario-failover` | Quatre HTTP 200 sur Backend 2 ; chaque trace montre tentative 1 du modèle dédié en erreur 404, puis tentative 2 réussie. |
| `scenario-token-rate` | A : un succès puis deux rejets 429 natifs `tokenLimit` ; B : deux succès 200. |
| `scenario-token-quota` | A : deux succès puis deux rejets 403 natifs `tokenLimit` ; B : deux succès 200. |
| `scenario-identity` | A 5/5 sur Backend 1, B 5/5 sur Backend 2 ; dix HTTP 200 et une seule tentative chacun. |

Preuves locales ignorées par Git : `.demo\fixed-initial-jobs.json`,
`.demo\fixed-failover-attempts.json` et `.demo\fixed-identity-verified.json`.
Les sept corps ARM complets et leurs ETags sont identiques dans
`.demo\fixed-aliases-before.json` et `.demo\fixed-aliases-after-initial.json`,
y compris `demo-chat`. Le runner ACI est resté arrêté.
La première certification de l'identité a été refusée : les dix spans étaient
arrivés, mais deux logs d'alias manquaient encore. La relecture stricte ultérieure
des **mêmes appels**, sans réémission, a passé les assertions. La console attend
désormais aussi les champs issus des jointures de logs et de stratégies avant de
certifier ; une valeur contradictoire présente reste un échec, pas une donnée ignorée.

Le correctif est déployé dans la révision prête `0000016`. Sa nouvelle recette
identité HTTPS a passé : dix HTTP 200, A 5/5 Backend 1 et B 5/5 Backend 2,
une tentative chacun, zéro retry client, Entra/CSRF/concurrence protégés.
Preuves : `.demo\fixed-final-identity-acceptance.json` et l'agrégat
`.demo\fixed-console-acceptance.json` (cinq scénarios de la révision `0000015`,
identité de la révision `0000016`, provenance explicitée).
Les snapshots finaux `.demo\fixed-baseline-after.json` et
`.demo\fixed-aliases-after.json` restent strictement identiques aux snapshots avant
recette, corps complets et ETags inclus. Le test Chromium de nettoyage DOM est
local et synthétique ; aucune observation visuelle du portail n'est revendiquée.

Les tests locaux sont synthétiques, pas des résultats Azure. Le test Chromium DOM
prouve l'effacement au clic Start avant chargement du nouveau job, puis l'absence
de preuves/cadenas hérités ; il utilise une API synthétique.
Les preuves historiques incluent `.demo\identity-console-acceptance.json`
(A 5/5 Backend 1, B 5/5 Backend 2) et le contrôle négatif cité plus haut.
Elles concernent l'ancienne configuration dynamique, pas les nouveaux alias fixes.

La recette de migration doit fournir un JSON HTTPS avec les traces natives pour
chaque alias, les snapshots intégraux/ETags de `demo-chat` avant/après, et le résultat
du test DOM. La matrice [capabilities](capabilities.md) distingue les contrats
publics des comportements observés. Pas de preuve de suppression effective,
de résilience régionale, de panne réseau réelle ou de limite monétaire certifiée.
