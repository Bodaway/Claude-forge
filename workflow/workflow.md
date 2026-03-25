# Workflow Git & Jira — Guide de l'équipe de développement

**Version :** 2.0

**Date :** 2026-03-24

---

## Légende

- **(W)** = En attente de l'équipe de développement (Wait on dev)
- **(S)** = En attente du client / stakeholder (Wait on stakeholder)

---

## Statuts Jira

```yaml
statuses:
  - id: 0
    name: "0. Ouvert"
    jira_transition_id: 2
    owner: client
  - id: 1
    name: "1. A chiffrer (W)"
    jira_transition_id: 3
    owner: dev
  - id: 2
    name: "2. A valider (S)"
    jira_transition_id: 4
    owner: client
  - id: 3
    name: "3. Backlog (W)"
    jira_transition_id: 5
    owner: dev
  - id: 4
    name: "4. En cours (W)"
    jira_transition_id: 6
    owner: dev
  - id: 5
    name: "5. A tester en interne (W)"
    jira_transition_id: 7
    owner: reviewer
  - id: 6
    name: "6. A déployer en recette (W)"
    jira_transition_id: 8
    owner: dev
  - id: 7
    name: "7. A recetter (W)"
    jira_transition_id: 9
    owner: dev
  - id: 8
    name: "8. A recetter (S)"
    jira_transition_id: 10
    owner: client
  - id: 9
    name: "9. A corriger (W)"
    jira_transition_id: 11
    owner: dev
  - id: 10.1
    name: "10.1 A déployer en production (W)"
    jira_transition_id: 16
    owner: dev
  - id: 10.2
    name: "10.2 A déployer en production avec réserve (W)"
    jira_transition_id: 17
    owner: dev
  - id: 11
    name: "11. En production"
    jira_transition_id: 18
    owner: dev
  - id: 12.1
    name: "12.1 Bloqué"
    jira_transition_id: 13
    owner: dev
  - id: 12.2
    name: "12.2 En pause"
    jira_transition_id: 12
    owner: dev
  - id: 13
    name: "13. Abandonné"
    jira_transition_id: 14
    owner: client
  - id: 14
    name: "14. Clos"
    jira_transition_id: 15
    owner: client
```

---

## 1. Vue d'ensemble

Ce document définit le workflow normalisé de l'équipe pour la gestion des tickets Jira et des branches Git. Chaque étape est accompagnée d'une checklist à respecter avant de passer au statut suivant.

### Principes fondamentaux

- La branche `main` est la branche d'intégration. Elle n'est pas synonyme de "production".
- L'image Docker buildée lors du déploiement en recette est **exactement** celle déployée en production. Aucun rebuild entre recette et prod.
- Un tag semver est posé automatiquement par la pipeline à chaque build.
- Le numéro de ticket Jira doit être traçable dans l'historique Git à tout moment.
- La branche `main` est protégée : tout merge passe par une Pull Request approuvée.

### Environnements

| Environnement  | Usage                                      | Déployé depuis                  |
|----------------|--------------------------------------------|---------------------------------|
| **Dev**        | Développement local                        | Branches locales                |
| **Staging**    | Test interne (review + tests fonctionnels) | Feature branches                |
| **Recette**    | Validation client (PO + stakeholders)      | `main`                          |
| **Production** | Live                                       | Image Docker validée en recette |

### Types de branches

| Préfixe    | Usage                               | Exemple                              |
|------------|-------------------------------------|--------------------------------------|
| `feat/`    | Nouvelle fonctionnalité             | `feat/PROJ-123-ajout-filtre-clients` |
| `fix/`     | Correction (recette ou bug interne) | `fix/PROJ-456-correction-calcul-tva` |
| `hotfix/`  | Correction critique en production   | `hotfix/PROJ-789-crash-login`        |
| `release/` | Agrégat batch de plusieurs tickets  | `release/sprint-12`                  |

### Convention de nommage des branches

```
<type>/PROJ-<numéro>-<description-courte-en-kebab-case>
```

Le numéro de ticket Jira (ex. `PROJ-123`) **doit** figurer dans le nom de la branche. Ce numéro doit rester visible dans l'historique Git (merge commits, messages de PR).

---

## 2. Checklists par statut Jira

### 0. Ouvert → 1. A chiffrer (W)

**Responsable :** PO / Client

- [ ] Le ticket contient une description fonctionnelle compréhensible
- [ ] Les critères d'acceptation sont définis
- [ ] Les pièces jointes / maquettes sont présentes si nécessaire
- [ ] La priorité est définie

---

### 1. A chiffrer (W) → 2. A valider (S)

**Responsable :** Développeur

- [ ] Le chiffrage est documenté sur le ticket
- [ ] Les risques techniques identifiés sont notés en commentaire
- [ ] Les dépendances avec d'autres tickets sont liées dans Jira

---

### 2. A valider (S) → 3. Backlog (W)

**Responsable :** Client

_Statut géré par le client — aucune action dev requise._

- [ ] Le client a validé le chiffrage et le périmètre

---

### 3. Backlog (W) → 4. En cours (W)

**Responsable :** Développeur assigné

- [ ] Le ticket est assigné
- [ ] Les critères d'acceptation sont lus et compris
- [ ] La branche est créée depuis `main` à jour (`git checkout main && git pull`)
- [ ] Si batch : la branche est créée depuis la branche `release/*` correspondante
- [ ] Le statut Jira est passé à "4. En cours (W)"

---

### 4. En cours (W) → 5. A tester en interne (W)

**Responsable :** Développeur assigné

- [ ] Le code est complet et respecte les critères d'acceptation
- [ ] Les tests unitaires / d'intégration sont écrits et passent en local
- [ ] Le build passe localement (`npm run build` / équivalent)
- [ ] Le numéro de ticket est présent dans le nom de la branche
- [ ] Les spécifications fonctionnelles et techniques sont à jour
- [ ] La Pull Request est créée sur Azure DevOps :
  - Titre : `PROJ-XXX — Description courte`
  - Description : résumé des changements, lien vers le ticket Jira
  - Branche cible : `main` (ou `release/*` si batch)
- [ ] La PR est assignée à un reviewer
- [ ] Le statut Jira est passé à "5. A tester en interne (W)"
- [ ] Remplir les heures passées (worklog) sur le ticket Jira

---

### 5. A tester en interne (W) — Checklist de review

**Responsable :** Reviewer (un autre dev que le porteur du ticket)

_En cas de validation, la description de la PR est ajoutée en commentaire du ticket Jira._

#### Revue de code

- [ ] Le code est lisible et maintenable
- [ ] Les conventions de l'équipe sont respectées
- [ ] Pas de failles de sécurité évidentes (injection, données sensibles exposées)
- [ ] Pas de régression sur le code existant
- [ ] Les tests sont pertinents et couvrent les cas principaux
- [ ] Les spécifications fonctionnelles et techniques sont à jour

#### Tests

- [ ] Les tests automatisés passent
- [ ] Les tests fonctionnels sont réalisés sur l'environnement de staging
- [ ] Le comportement correspond aux critères d'acceptation du ticket

#### Décision

- [ ] **Approuvé** → La PR est validée, passer au statut suivant
- [ ] Remplir les heures passées (worklog) de la review sur le ticket Jira
- [ ] Copier la description de la PR en commentaire du ticket Jira
- [ ] **Retour** → Commentaires laissés sur la PR, le ticket revient à "4. En cours (W)"

---

### 5. A tester en interne (W) → 6. A déployer en recette (W)

**Responsable :** Reviewer

- [ ] La PR est approuvée par le reviewer
- [ ] Supprimer la branche feature après le merge de la PR
- [ ] Le commentaire de résolution de la PR est ajouté en commentaire du ticket Jira
- [ ] Aucun conflit de merge non résolu
- [ ] Si batch : vérifier que tous les tickets du batch sont mergés sur la release
- [ ] Une version est créée dans Jira et un plan de MEP est rédigé
- [ ] Le statut Jira est passé à "6. A déployer en recette (W)"

---

### 6. A déployer en recette (W) → 7. A recetter (W)

**Responsable :** Développeur assigné

- [ ] La PR est mergée sur `main` (ou `release/*` → `main` si batch)
- [ ] Vérifier que `main` est dans un état stable (pas de merge en cours d'un autre ticket)
- [ ] Déclencher la pipeline de déploiement en recette
- [ ] Vérifier que le build et le déploiement se sont terminés sans erreur
- [ ] Faire un smoke test rapide sur l'environnement de recette
- [ ] Le statut Jira est passé à "7. A recetter (W)"

---

### 7. A recetter (W) → 8. A recetter (S)

**Responsable :** Développeur assigné

- [ ] Vérification fonctionnelle rapide sur l'environnement de recette
- [ ] Les scénarios de test principaux sont validés
- [ ] Le statut Jira est passé à "8. A recetter (S)"
- [ ] Le PO / client est notifié que le ticket est prêt à recetter

---

### 8. A recetter (S) — Attente validation client

**Responsable :** Client / PO

_Statut géré par le client — aucune action dev requise. En attente de retour._

---

### 9. A corriger (W) → 4. En cours (W)

**Responsable :** Développeur assigné

- [ ] Lire les commentaires du client sur le ticket Jira
- [ ] Créer une nouvelle branche de fix depuis `main` (`git checkout main && git pull`)
- [ ] Ne **pas** réouvrir l'ancienne branche (risque de désynchronisation avec `main`)
- [ ] Le statut Jira est repassé à "4. En cours (W)"
- [ ] Reprendre le cycle normal : correction → review → merge → redéploiement recette

---

### 10.1 A déployer en production (W) → 11. En production

**Responsable :** Développeur assigné + PO

- [ ] L'approbation du PO est formalisée sur le ticket Jira
- [ ] Déclencher la pipeline de déploiement en production avec **l'image Docker identique** à celle validée en recette
- [ ] Vérifier que le déploiement s'est terminé sans erreur
- [ ] Faire un smoke test sur l'environnement de production
- [ ] Le statut Jira est passé à "11. En production"

---

### 10.2 A déployer en production avec réserve (W) → 11. En production

**Responsable :** Développeur assigné + PO

_Ce statut indique que le client a validé la fonctionnalité mais avec des réserves (ajustements mineurs à prévoir après mise en production)._

- [ ] L'approbation du PO est formalisée sur le ticket Jira, avec les réserves documentées
- [ ] Les réserves sont créées en tant que nouveaux tickets Jira liés
- [ ] Déclencher la pipeline de déploiement en production avec **l'image Docker identique** à celle validée en recette
- [ ] Vérifier que le déploiement s'est terminé sans erreur
- [ ] Faire un smoke test sur l'environnement de production
- [ ] Le statut Jira est passé à "11. En production"

---

### 11. En production → 14. Clos

**Responsable :** PO / Client

- [ ] Aucune régression critique détectée en production
- [ ] Le PO confirme la mise en production
- [ ] Le statut Jira est passé à "14. Clos"

---

### 13. Abandonné

**Responsable :** Client / PO

- [ ] La raison de l'abandon est documentée en commentaire sur le ticket
- [ ] Si une branche existe, elle est supprimée
- [ ] Si une PR existe, elle est fermée (pas mergée)
- [ ] Le statut Jira est passé à "13. Abandonné"

---

### 12.1 Bloqué / 12.2 En pause

**Responsable :** Développeur assigné

- [ ] La raison du blocage / de la pause est documentée en commentaire sur le ticket
- [ ] Le bloqueur est identifié (ticket lié, dépendance externe, attente d'info)
- [ ] Le bloqueur est signalé en daily
- [ ] À la reprise : vérifier que la branche est à jour avec `main` avant de continuer

---

## 3. Gestion des releases batch

### Processus

1. Créer la branche `release/sprint-XX` depuis `main`
2. Chaque ticket du batch est mergé (`feat/` ou `fix/`) vers la branche `release/*`
3. Les conflits sont résolus sur la branche `release/*`
4. Une fois tous les tickets du batch mergés, la branche `release/*` est mergée sur `main` via PR
5. Le déploiement en recette est déclenché depuis `main`

### Règle de priorité de merge

Pendant la phase de préparation d'un batch, la branche `release/*` a priorité pour le merge sur `main`. Les merges de tickets solo (hors batch) restent possibles, mais :

- Le code solo ne sera **pas** inclus dans l'image de recette du batch en cours
- Il faudra attendre le prochain cycle de déploiement en recette
- En cas de conflit avec le batch sur `main`, c'est le batch qui prime

### Fréquence

Un batch par sprint. Les tickets solo peuvent être déployés entre deux batches selon les besoins.

---

## 4. Règles de protection de branche `main`

Règles à configurer dans Azure DevOps :

- Aucun push direct sur `main` — passage obligatoire par Pull Request
- Minimum 1 approbation requise sur chaque PR
- Le build doit passer avant le merge
- La branche doit être à jour avec `main` avant le merge

---

## 5. Hotfix — Correction critique en production

### Quand utiliser un hotfix

Un hotfix est déclenché uniquement lorsqu'un bug critique est détecté en production et que le cycle normal (recette complète) ne peut pas être attendu. Exemples : crash applicatif, fuite de données, blocage fonctionnel majeur.

### Processus

**Responsable :** Développeur assigné + PO

1. Créer un ticket Jira dédié avec la priorité **Critique** ou **Bloquante**
2. Créer une branche `hotfix/PROJ-XXX-description` depuis `main`
3. Implémenter le correctif minimal (pas de refactoring, pas de fonctionnalités additionnelles)
4. Créer une PR vers `main` avec review accélérée (1 approbation minimum)
5. Merger la PR sur `main`
6. Déclencher la pipeline de déploiement en recette
7. Valider le correctif sur l'environnement de recette (smoke test ciblé)
8. Déployer en production avec l'image validée en recette
9. Faire un smoke test sur l'environnement de production
10. Passer le ticket Jira à "11. En production" puis "14. Clos"

### Règles

- Le hotfix doit rester **minimal** : uniquement le correctif du bug critique
- Le PO doit valider le déploiement en production, même en procédure accélérée
- Un post-mortem est recommandé pour les incidents majeurs
