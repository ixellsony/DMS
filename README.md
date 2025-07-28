# DMS - Dashboard Monitoring Serveur

**DMS** (Dashboard Monitoring Serveur) est un outil léger permettant de monitorer facilement l'état de vos serveurs via une interface dashboard.  Il se compose d'une partie **serveur** et d'une partie **client**.

## Fonctionnement

- **Serveur :** Il suffit de lancer le script `srv.rb` sur la machine qui centralisera les données.
- **Client :** Sur chaque serveur à monitorer, exécutez le script `install.sh`. Celui-ci installe automatiquement les dépendances et configure le client (`client.rb`) pour envoyer les métriques au serveur DMS.

## Installation

### Côté serveur

```bash
ruby srv.rb
```
### Côté client

```bash
./install.sh https://mon-serveur-dms.com/metrics
```
