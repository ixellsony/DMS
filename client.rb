#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'uri'
require 'socket'

class ServerMonitor
  def initialize(manager_url)
    @manager_url = manager_url
    @server_name = Socket.gethostname
    @send_interval = 30 # secondes
  end

  def start
    puts "Démarrage du monitoring pour #{@server_name}"
    puts "Envoi des données vers #{@manager_url}"
    
    loop do
      begin
        data = collect_metrics
        send_metrics(data)
        puts "Données envoyées: #{data}"
      rescue => e
        puts "Erreur: #{e.message}"
      end
      
      sleep @send_interval
    end
  end

  private

  def collect_metrics
    {
      server_name: @server_name,
      timestamp: Time.now.to_i,
      temperature: get_temperature,
      memory: get_memory_usage,
      storage: get_storage_usage,
      cpu: get_cpu_usage
    }
  end

  def get_temperature
    # Priorité 1: Temperature CPU via sensors (Package id)
    begin
      output = `sensors 2>/dev/null`
      if output && !output.empty?
        # Cherche la température du CPU (Package id)
        cpu_match = output.match(/Package id \d+:\s*\+?(\d+\.?\d*)°C/)
        return cpu_match[1].to_f if cpu_match
        
        # Fallback: cherche coretemp avec une regex plus précise
        lines = output.split("\n")
        coretemp_section = false
        lines.each do |line|
          if line.include?("coretemp")
            coretemp_section = true
            next
          end
          if coretemp_section && line.match(/Core \d+:\s*\+?(\d+\.?\d*)°C/)
            temp = line.match(/\+?(\d+\.?\d*)°C/)[1].to_f
            return temp
          end
        end
      end
    rescue
    end
    
    # Priorité 2: Fichiers système thermal_zone
    temp_sources = [
      "/sys/class/thermal/thermal_zone0/temp",
      "/sys/class/thermal/thermal_zone1/temp",
      "/sys/class/thermal/thermal_zone2/temp"
    ]
    
    temp_sources.each do |source|
      if File.exist?(source)
        begin
          temp = File.read(source).strip.to_i
          if temp > 0
            celsius = temp / 1000.0
            # Évite les températures trop élevées (probablement pas CPU)
            return celsius if celsius < 80
          end
        rescue
        end
      end
    end
    
    0.0 # Valeur par défaut si pas de température disponible
  end

  def get_memory_usage
    # Lecture de /proc/meminfo
    meminfo = File.read("/proc/meminfo")
    
    total = meminfo.match(/MemTotal:\s+(\d+) kB/)[1].to_i
    free = meminfo.match(/MemFree:\s+(\d+) kB/)[1].to_i
    buffers = meminfo.match(/Buffers:\s+(\d+) kB/)[1].to_i
    cached = meminfo.match(/Cached:\s+(\d+) kB/)[1].to_i
    
    used = total - free - buffers - cached
    
    {
      used: (used / 1024.0).round(2), # MB
      total: (total / 1024.0).round(2), # MB
      percentage: ((used.to_f / total) * 100).round(2)
    }
  end

  def get_storage_usage
    # Utilise df pour obtenir l'usage du disque racine
    output = `df -h / | tail -1`
    parts = output.split
    
    {
      used: parts[2],
      total: parts[1],
      percentage: parts[4].gsub('%', '').to_i
    }
  end

  def get_cpu_usage
    # Méthode simple: lecture de /proc/stat
    stat1 = File.read("/proc/stat").lines.first
    values1 = stat1.split[1..-1].map(&:to_i)
    
    sleep 1
    
    stat2 = File.read("/proc/stat").lines.first
    values2 = stat2.split[1..-1].map(&:to_i)
    
    # Calcul du pourcentage CPU
    total1 = values1.sum
    total2 = values2.sum
    
    idle1 = values1[3]
    idle2 = values2[3]
    
    total_diff = total2 - total1
    idle_diff = idle2 - idle1
    
    cpu_percent = ((total_diff - idle_diff).to_f / total_diff * 100).round(2)
    cpu_percent
  end

  def send_metrics(data)
    uri = URI(@manager_url)
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true if uri.scheme == 'https'
    
    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = 'application/json'
    request.body = data.to_json
    
    response = http.request(request)
    
    unless response.code == '200'
      raise "Erreur HTTP: #{response.code} - #{response.message}"
    end
  end
end

# Configuration
if ARGV.length < 1
  puts "Usage: ruby client.rb <manager_url>"
  puts "Exemple: ruby client.rb http://192.168.1.100:4567/metrics"
  exit 1
end

manager_url = ARGV[0]

# Démarrage du monitoring
monitor = ServerMonitor.new(manager_url)
monitor.start
