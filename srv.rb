#!/usr/bin/env ruby

require 'optparse'
require 'sqlite3'
require 'json'

# ===== GESTION DES ARGUMENTS CLI EN PREMIER =====

def show_help
  puts <<~HELP
    Usage: #{$0} [OPTIONS]
    
    Options:
      -l, --list                 Affiche la liste des serveurs
      -c, --clean SERVER         Supprime un serveur spécifique
      -C, --cleanup [HOURS]      Supprime les serveurs inactifs (défaut: 24h)
      -s, --stats                Affiche les statistiques de la base
      -h, --help                 Affiche cette aide
      
    Exemples:
      #{$0}                      # Démarre le serveur web
      #{$0} -l                   # Liste tous les serveurs
      #{$0} -c srv1              # Supprime le serveur 'srv1'
      #{$0} -C                   # Supprime les serveurs inactifs depuis 24h
      #{$0} -C 48                # Supprime les serveurs inactifs depuis 48h
      #{$0} -s                   # Affiche les statistiques
  HELP
end

def time_ago_in_words(time)
  seconds = Time.now - time
  
  case seconds
  when 0..59
    "#{seconds.to_i}s"
  when 60..3599
    "#{(seconds / 60).to_i}min"
  when 3600..86399
    "#{(seconds / 3600).to_i}h"
  else
    "#{(seconds / 86400).to_i}j"
  end
end

def list_servers
  db = SQLite3::Database.new('monitoring.db')
  db.results_as_hash = true
  
  sql = <<-SQL
    SELECT m1.* FROM metrics m1
    INNER JOIN (
      SELECT server_name, MAX(timestamp) as max_timestamp
      FROM metrics
      GROUP BY server_name
    ) m2 ON m1.server_name = m2.server_name AND m1.timestamp = m2.max_timestamp
    ORDER BY m1.timestamp DESC
  SQL
  
  results = db.execute(sql)
  db.close
  
  puts "\n=== LISTE DES SERVEURS ==="
  puts "%-20s %-10s %-15s %-10s %-10s %-10s" % ["Nom", "Statut", "Dernière vue", "CPU %", "RAM %", "Stockage %"]
  puts "-" * 85
  
  if results.empty?
    puts "Aucun serveur trouvé."
  else
    results.each do |server|
      last_seen = Time.at(server['timestamp'])
      status = (Time.now - last_seen) < 120 ? 'EN LIGNE' : 'HORS LIGNE'
      last_seen_human = time_ago_in_words(last_seen)
      
      # Couleurs pour le terminal
      status_color = status == 'EN LIGNE' ? "\e[32m" : "\e[31m"  # Vert ou Rouge
      reset_color = "\e[0m"
      
      puts "%-20s %s%-10s%s %-15s %-10.1f %-10.1f %-10d" % [
        server['server_name'],
        status_color,
        status,
        reset_color,
        last_seen_human,
        server['cpu_percentage'],
        server['memory_percentage'],
        server['storage_percentage']
      ]
    end
  end
  
  puts "\nTotal: #{results.length} serveur(s)"
  puts "En ligne: #{results.count { |s| (Time.now - Time.at(s['timestamp'])) < 120 }}"
  puts "Hors ligne: #{results.count { |s| (Time.now - Time.at(s['timestamp'])) >= 120 }}"
  puts
end

def clean_server(server_name)
  db = SQLite3::Database.new('monitoring.db')
  
  # Vérifie si le serveur existe
  count = db.execute("SELECT COUNT(*) FROM metrics WHERE server_name = ?", [server_name])[0][0]
  
  if count == 0
    puts "\e[31mErreur: Serveur '#{server_name}' non trouvé.\e[0m"
    db.close
    return false
  end
  
  # Affiche les infos du serveur avant suppression
  server_info = db.execute("SELECT server_name, COUNT(*) as records, MIN(timestamp) as first_seen, MAX(timestamp) as last_seen FROM metrics WHERE server_name = ? GROUP BY server_name", [server_name])[0]
  
  puts "\n=== INFORMATIONS DU SERVEUR ==="
  puts "Nom: #{server_info[0]}"
  puts "Nombre d'enregistrements: #{server_info[1]}"
  puts "Premier enregistrement: #{Time.at(server_info[2])}"
  puts "Dernier enregistrement: #{Time.at(server_info[3])}"
  
  # Confirmation
  print "\nÊtes-vous sûr de vouloir supprimer ce serveur et toutes ses données ? (oui/non): "
  confirmation = gets.chomp.downcase
  
  if confirmation == 'oui' || confirmation == 'o'
    # Supprime toutes les métriques du serveur
    db.execute("DELETE FROM metrics WHERE server_name = ?", [server_name])
    deleted_count = db.changes
    
    puts "\e[32m✓ Serveur '#{server_name}' supprimé avec succès (#{deleted_count} enregistrements supprimés).\e[0m"
    db.close
    return true
  else
    puts "\e[33mSuppression annulée.\e[0m"
    db.close
    return false
  end
end

def cleanup_inactive(hours = 24)
  cutoff_time = Time.now.to_i - (hours * 60 * 60)
  
  db = SQLite3::Database.new('monitoring.db')
  
  # Trouve les serveurs à supprimer
  sql = <<-SQL
    SELECT server_name, MAX(timestamp) as last_seen
    FROM metrics 
    GROUP BY server_name
    HAVING MAX(timestamp) < ?
  SQL
  
  servers_to_delete = db.execute(sql, [cutoff_time])
  
  if servers_to_delete.empty?
    puts "\e[32mAucun serveur inactif trouvé (seuil: #{hours}h).\e[0m"
    db.close
    return
  end
  
  puts "\n=== SERVEURS INACTIFS (plus de #{hours}h) ==="
  servers_to_delete.each do |server|
    last_seen = Time.at(server[1])
    puts "- #{server[0]} (dernière vue: #{last_seen})"
  end
  
  print "\nSupprimer ces #{servers_to_delete.length} serveur(s) ? (oui/non): "
  confirmation = gets.chomp.downcase
  
  if confirmation == 'oui' || confirmation == 'o'
    # Supprime les serveurs inactifs
    server_names = servers_to_delete.map { |row| row[0] }
    placeholders = server_names.map { '?' }.join(',')
    
    db.execute("DELETE FROM metrics WHERE server_name IN (#{placeholders})", server_names)
    deleted_count = db.changes
    
    puts "\e[32m✓ #{server_names.length} serveur(s) supprimé(s) (#{deleted_count} enregistrements supprimés).\e[0m"
    puts "Serveurs supprimés:"
    server_names.each { |name| puts "  - #{name}" }
  else
    puts "\e[33mSuppression annulée.\e[0m"
  end
  
  db.close
end

def show_stats
  db = SQLite3::Database.new('monitoring.db')
  
  # Statistiques générales
  total_records = db.execute("SELECT COUNT(*) FROM metrics")[0][0]
  total_servers = db.execute("SELECT COUNT(DISTINCT server_name) FROM metrics")[0][0]
  
  # Période de données
  first_record = db.execute("SELECT MIN(timestamp) FROM metrics")[0][0]
  last_record = db.execute("SELECT MAX(timestamp) FROM metrics")[0][0]
  
  # Taille de la base
  db_size = File.size('monitoring.db')
  
  puts "\n=== STATISTIQUES DE LA BASE ==="
  puts "Nombre total d'enregistrements: #{total_records}"
  puts "Nombre de serveurs: #{total_servers}"
  puts "Taille de la base: #{(db_size / 1024.0 / 1024.0).round(2)} MB"
  
  if first_record && last_record
    puts "Période de données: #{Time.at(first_record)} à #{Time.at(last_record)}"
    puts "Durée couverte: #{((last_record - first_record) / 86400.0).round(1)} jours"
  end
  
  db.close
end

# Traitement des arguments CLI
if ARGV.length > 0
  options = {}
  
  OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} [options]"
    
    opts.on('-l', '--list', 'Affiche la liste des serveurs') do
      options[:list] = true
    end
    
    opts.on('-c', '--clean SERVER', 'Supprime un serveur spécifique') do |server|
      options[:clean] = server
    end
    
    opts.on('-C', '--cleanup [HOURS]', Integer, 'Supprime les serveurs inactifs (défaut: 24h)') do |hours|
      options[:cleanup] = hours || 24
    end
    
    opts.on('-s', '--stats', 'Affiche les statistiques de la base') do
      options[:stats] = true
    end
    
    opts.on('-h', '--help', 'Affiche cette aide') do
      show_help
      exit
    end
  end.parse!
  
  # Exécute la commande demandée
  if options[:list]
    list_servers
  elsif options[:clean]
    clean_server(options[:clean])
  elsif options[:cleanup]
    cleanup_inactive(options[:cleanup])
  elsif options[:stats]
    show_stats
  else
    show_help
  end
  
  exit
end

# ===== CHARGEMENT DE SINATRA SEULEMENT SI MODE SERVEUR WEB =====

require 'sinatra'
require 'erb'

class ServerManager < Sinatra::Base
  def initialize
    super
    setup_database
  end

  configure do
    set :port, 4777
    set :bind, '127.0.0.1'
    set :views, File.dirname(__FILE__)
    set :public_folder, File.dirname(__FILE__) + '/public'
    set :host_authorization, { permitted_hosts: ["manager.n27.fr"] }
  end

  # Page principale du dashboard
  get '/' do
    @servers = get_recent_server_data
    erb :index
  end

  # API pour recevoir les métriques des serveurs
  post '/metrics' do
    content_type :json
    
    begin
      data = JSON.parse(request.body.read)
      
      # Validation des données
      required_fields = ['server_name', 'timestamp', 'temperature', 'memory', 'storage', 'cpu']
      missing_fields = required_fields.select { |field| !data.key?(field) }
      
      if missing_fields.any?
        status 400
        return { error: "Champs manquants: #{missing_fields.join(', ')}" }.to_json
      end
      
      # Sauvegarde en base
      save_metrics(data)
      
      { status: 'success', message: 'Métriques sauvegardées' }.to_json
    rescue JSON::ParserError
      status 400
      { error: 'JSON invalide' }.to_json
    rescue => e
      status 500
      { error: "Erreur serveur: #{e.message}" }.to_json
    end
  end

  # API pour récupérer les données d'un serveur
  get '/api/server/:name' do
    content_type :json
    server_name = params[:name]
    
    db = SQLite3::Database.new('monitoring.db')
    db.results_as_hash = true
    
    # Récupère les 24 dernières entrées (dernières 12h si envoi toutes les 30s)
    sql = <<-SQL
      SELECT * FROM metrics 
      WHERE server_name = ? 
      ORDER BY timestamp DESC 
      LIMIT 24
    SQL
    
    results = db.execute(sql, [server_name])
    db.close
    
    results.to_json
  end

  # API pour la liste des serveurs
  get '/api/servers' do
    content_type :json
    
    db = SQLite3::Database.new('monitoring.db')
    db.results_as_hash = true
    
    sql = <<-SQL
      SELECT server_name, 
             MAX(timestamp) as last_seen,
             COUNT(*) as total_metrics
      FROM metrics 
      GROUP BY server_name
      ORDER BY last_seen DESC
    SQL
    
    results = db.execute(sql)
    db.close
    
    results.to_json
  end

  private

  def setup_database
    db = SQLite3::Database.new('monitoring.db')
    
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS metrics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_name TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        temperature REAL,
        memory_used REAL,
        memory_total REAL,
        memory_percentage REAL,
        storage_used TEXT,
        storage_total TEXT,
        storage_percentage INTEGER,
        cpu_percentage REAL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    SQL
    
    # Index pour les performances
    db.execute "CREATE INDEX IF NOT EXISTS idx_server_timestamp ON metrics(server_name, timestamp)"
    
    db.close
    puts "Base de données initialisée"
  end

  def save_metrics(data)
    db = SQLite3::Database.new('monitoring.db')
    
    sql = <<-SQL
      INSERT INTO metrics (
        server_name, timestamp, temperature,
        memory_used, memory_total, memory_percentage,
        storage_used, storage_total, storage_percentage,
        cpu_percentage
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    
    db.execute(sql, [
      data['server_name'],
      data['timestamp'],
      data['temperature'],
      data['memory']['used'],
      data['memory']['total'],
      data['memory']['percentage'],
      data['storage']['used'],
      data['storage']['total'],
      data['storage']['percentage'],
      data['cpu']
    ])
    
    # NOUVELLE LOGIQUE : Nettoyage intelligent de l'historique
    cleanup_old_metrics(db, data['server_name'])
    
    db.close
  end

  def cleanup_old_metrics(db, current_server_name)
    # Limite de 24h pour l'historique
    cutoff_time = Time.now.to_i - (24 * 60 * 60)
    
    # Pour chaque serveur, on garde :
    # 1. Toutes les métriques des dernières 24h
    # 2. La dernière métrique (même si > 24h) pour garder la trace du serveur
    
    # Trouve tous les serveurs dans la base
    servers = db.execute("SELECT DISTINCT server_name FROM metrics")
    
    servers.each do |server_row|
      server_name = server_row[0]
      
      # Trouve la dernière métrique de ce serveur
      last_metric = db.execute(
        "SELECT id, timestamp FROM metrics WHERE server_name = ? ORDER BY timestamp DESC LIMIT 1", 
        [server_name]
      )[0]
      
      next unless last_metric
      
      last_metric_id = last_metric[0]
      last_metric_timestamp = last_metric[1]
      
      # Supprime les anciennes métriques SAUF :
      # - Les métriques des dernières 24h
      # - La dernière métrique (pour garder la trace du serveur)
      delete_sql = <<-SQL
        DELETE FROM metrics 
        WHERE server_name = ? 
        AND timestamp < ? 
        AND id != ?
      SQL
      
      db.execute(delete_sql, [server_name, cutoff_time, last_metric_id])
      deleted_count = db.changes
      
      if deleted_count > 0
        puts "Serveur #{server_name}: #{deleted_count} anciennes métriques supprimées (> 24h)"
      end
    end
  end

  def get_recent_server_data
    db = SQLite3::Database.new('monitoring.db')
    db.results_as_hash = true
    
    sql = <<-SQL
      SELECT m1.* FROM metrics m1
      INNER JOIN (
        SELECT server_name, MAX(timestamp) as max_timestamp
        FROM metrics
        GROUP BY server_name
      ) m2 ON m1.server_name = m2.server_name AND m1.timestamp = m2.max_timestamp
      ORDER BY m1.timestamp DESC
    SQL
    
    results = db.execute(sql)
    db.close
    
    # Ajoute le statut (online/offline)
    results.each do |server|
      last_seen = Time.at(server['timestamp'])
      server['status'] = (Time.now - last_seen) < 120 ? 'online' : 'offline'
      server['last_seen_human'] = time_ago_in_words(last_seen)
    end
    
    results
  end

  def time_ago_in_words(time)
    seconds = Time.now - time
    
    case seconds
    when 0..59
      "#{seconds.to_i} secondes"
    when 60..3599
      "#{(seconds / 60).to_i} minutes"
    when 3600..86399
      "#{(seconds / 3600).to_i} heures"
    else
      "#{(seconds / 86400).to_i} jours"
    end
  end
end

# Démarrage du serveur web si aucun argument CLI
if __FILE__ == $0
  puts "Démarrage du serveur de monitoring sur http://0.0.0.0:4567"
  puts "Utilisez #{$0} -h pour voir les options en ligne de commande"
  ServerManager.run!
end
