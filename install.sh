#!/bin/bash

# Script d'installation du client de monitoring
# Usage: sudo ./install.sh <manager_url>

set -e

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SERVICE_NAME="server-monitor"
INSTALL_DIR="/opt/server-monitor"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_DIR="/var/log/server-monitor"

# Fonction d'affichage
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Vérification des arguments
if [ $# -ne 1 ]; then
    print_error "Usage: sudo $0 <manager_url>"
    print_error "Exemple: sudo $0 https://manager.n27.fr/metrics"
    exit 1
fi

MANAGER_URL="$1"

# Vérification des privilèges root
if [ "$EUID" -ne 0 ]; then
    print_error "Ce script doit être exécuté en tant que root (sudo)"
    exit 1
fi

# Vérification de l'URL
if [[ ! "$MANAGER_URL" =~ ^https?://.*/.* ]]; then
    print_error "L'URL semble incorrecte. Format attendu: http(s)://domain/path"
    print_error "Exemple: https://manager.n27.fr/metrics"
    exit 1
fi

print_status "=== Installation du client de monitoring ==="
print_status "URL du manager: $MANAGER_URL"
print_status "Hostname: $(hostname)"

# Vérification si c'est une réinstallation
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    print_warning "Service $SERVICE_NAME déjà actif. Arrêt en cours..."
    systemctl stop "$SERVICE_NAME"
fi

if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    print_warning "Service $SERVICE_NAME déjà installé. Mise à jour en cours..."
    systemctl disable "$SERVICE_NAME"
fi

# Test de connectivité OBLIGATOIRE
print_status "Test de connectivité vers le manager..."
if ! command -v curl &> /dev/null; then
    print_error "curl n'est pas installé. Installation requise pour tester la connectivité."
    if command -v apt-get &> /dev/null; then
        apt-get update
        apt-get install -y curl
    elif command -v yum &> /dev/null; then
        yum install -y curl
    elif command -v dnf &> /dev/null; then
        dnf install -y curl
    else
        print_error "Impossible d'installer curl. Installez-le manuellement."
        exit 1
    fi
fi

# Test de connectivité strict
BASE_URL=$(echo "$MANAGER_URL" | sed 's|/metrics$||')
print_status "Test de connectivité vers $BASE_URL..."

if ! curl -s --connect-timeout 10 --max-time 30 "$BASE_URL" > /dev/null 2>&1; then
    print_error "Impossible de contacter $BASE_URL"
    print_error "Vérifiez que:"
    print_error "  1. L'URL est correcte"
    print_error "  2. Le serveur manager est accessible"
    print_error "  3. Il n'y a pas de problème de réseau/firewall"
    print_error ""
    print_error "Installation annulée pour éviter un service non fonctionnel."
    exit 1
fi

print_success "Connectivité OK vers $BASE_URL"

# Test spécifique du endpoint metrics
print_status "Test du endpoint metrics..."
if curl -s --connect-timeout 10 --max-time 30 "$MANAGER_URL" > /dev/null 2>&1; then
    print_success "Endpoint metrics accessible"
else
    print_warning "Endpoint metrics non accessible mais URL de base OK"
    print_warning "Le service sera installé mais pourrait ne pas fonctionner correctement"
    read -p "Continuer quand même ? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Installation annulée par l'utilisateur"
        exit 1
    fi
fi

# Vérification de Ruby
print_status "Vérification de Ruby..."
if ! command -v ruby &> /dev/null; then
    print_error "Ruby n'est pas installé. Installation en cours..."
    if command -v apt-get &> /dev/null; then
        apt-get update
        apt-get install -y ruby ruby-dev
    elif command -v yum &> /dev/null; then
        yum install -y ruby ruby-devel
    elif command -v dnf &> /dev/null; then
        dnf install -y ruby ruby-devel
    else
        print_error "Gestionnaire de paquets non supporté. Installez Ruby manuellement."
        exit 1
    fi
fi

# Vérification des gems
print_status "Vérification des gems Ruby..."
if ! gem list | grep -q "^json "; then
    print_status "Installation de la gem json..."
    gem install json
fi

# Création du répertoire d'installation
print_status "Création du répertoire d'installation..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"

# Vérification du fichier client.rb
if [ ! -f "client.rb" ]; then
    print_error "Le fichier client.rb n'est pas trouvé dans le répertoire courant"
    exit 1
fi

# Copie du client
print_status "Installation du client..."
cp client.rb "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/client.rb"

# Création du fichier de configuration
print_status "Création de la configuration..."
cat > "$INSTALL_DIR/config" << EOF
# Configuration du client de monitoring
MANAGER_URL="$MANAGER_URL"
EOF

# Création du service systemd (corrigé)
print_status "Création du service systemd..."
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Server Monitor Client
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=$INSTALL_DIR/config
ExecStart=/usr/bin/ruby $INSTALL_DIR/client.rb \$MANAGER_URL
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/monitor.log
StandardError=append:$LOG_DIR/monitor.log

# Sécurité
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$LOG_DIR

[Install]
WantedBy=multi-user.target
EOF

# Configuration de la rotation des logs
print_status "Configuration de la rotation des logs..."
cat > "/etc/logrotate.d/server-monitor" << EOF
$LOG_DIR/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 root root
    postrotate
        systemctl reload-or-restart $SERVICE_NAME
    endscript
}
EOF

# Activation et démarrage du service
print_status "Activation du service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Attendre un peu pour vérifier le statut
sleep 5

# Vérification du statut
if systemctl is-active --quiet "$SERVICE_NAME"; then
    print_success "Service démarré avec succès!"
else
    print_error "Erreur lors du démarrage du service"
    print_status "Logs du service:"
    systemctl status "$SERVICE_NAME" --no-pager
    journalctl -u "$SERVICE_NAME" --no-pager -n 20
    exit 1
fi

# Test final de fonctionnement
print_status "Test final de fonctionnement..."
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
    print_success "Service stable et fonctionnel"
    
    # Vérification des logs pour des erreurs
    if journalctl -u "$SERVICE_NAME" --since "1 minute ago" | grep -i error > /dev/null 2>&1; then
        print_warning "Des erreurs ont été détectées dans les logs récents"
        print_status "Consultez les logs avec: monitor-ctl logs"
    fi
else
    print_error "Le service s'est arrêté après le démarrage"
    print_status "Logs d'erreur:"
    journalctl -u "$SERVICE_NAME" --no-pager -n 20
    exit 1
fi

# Création d'un script de gestion
print_status "Création du script de gestion..."
cat > "/usr/local/bin/monitor-ctl" << 'EOF'
#!/bin/bash

SERVICE_NAME="server-monitor"
LOG_DIR="/var/log/server-monitor"

case "$1" in
    start)
        echo "Démarrage du monitoring..."
        systemctl start $SERVICE_NAME
        ;;
    stop)
        echo "Arrêt du monitoring..."
        systemctl stop $SERVICE_NAME
        ;;
    restart)
        echo "Redémarrage du monitoring..."
        systemctl restart $SERVICE_NAME
        ;;
    status)
        systemctl status $SERVICE_NAME --no-pager
        ;;
    logs)
        if [ "$2" = "-f" ]; then
            journalctl -u $SERVICE_NAME -f
        else
            journalctl -u $SERVICE_NAME --no-pager -n 50
        fi
        ;;
    tail)
        tail -f $LOG_DIR/monitor.log
        ;;
    config)
        echo "Configuration actuelle:"
        cat /opt/server-monitor/config
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|tail|config}"
        echo "  start   - Démarre le service"
        echo "  stop    - Arrête le service"
        echo "  restart - Redémarre le service"
        echo "  status  - Affiche le statut du service"
        echo "  logs    - Affiche les logs (ajoutez -f pour suivre)"
        echo "  tail    - Affiche les logs en temps réel"
        echo "  config  - Affiche la configuration actuelle"
        exit 1
        ;;
esac
EOF

chmod +x "/usr/local/bin/monitor-ctl"

# Résumé de l'installation
echo
print_success "=== Installation terminée avec succès! ==="
echo
print_status "Configuration:"
print_status "  - Service: $SERVICE_NAME"
print_status "  - Répertoire: $INSTALL_DIR"
print_status "  - Logs: $LOG_DIR/monitor.log"
print_status "  - Manager: $MANAGER_URL"
print_status "  - Hostname: $(hostname)"
echo
print_status "Commandes de gestion:"
print_status "  monitor-ctl status   # Statut du service"
print_status "  monitor-ctl logs     # Voir les logs"
print_status "  monitor-ctl tail     # Suivre les logs en temps réel"
print_status "  monitor-ctl restart  # Redémarrer le service"
print_status "  monitor-ctl config   # Voir la configuration"
echo
print_status "Pour changer l'URL du manager, relancez simplement:"
print_status "  sudo $0 <nouvelle_url>"
echo
print_status "Le service démarre automatiquement au boot du système."
print_status "Statut actuel:"
systemctl status "$SERVICE_NAME" --no-pager -l

echo
print_success "Le serveur $(hostname) envoie maintenant ses métriques vers votre dashboard!"
