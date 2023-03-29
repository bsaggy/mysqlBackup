#!/usr/bin/env ruby


require 'pry-byebug'
require 'zabbix_sender_api'
require 'optimist'
require 'benchmark'
require 'date'
require 'logger'


opts = Optimist::options do
  opt :zabhost, "Zabbix host to attach data to", :type => :string, :required => true
  opt :zabproxy, "Zabbix proxy/server to send data to", :type => :string, :required => true
  opt :zabsender, "Path to Zabbix Sender", :type => :string, :default => "/usr/bin/zabbix_sender"
  opt :mysqlhost, "Hostname or IP of mysql DB host", :type => :string, :default => "127.0.0.1"
  opt :mysqluser, "Username of mysql DB", :type => :string, :required => true
  opt :mysqlpass, "Password of mysql DB", :type => :string, :required => true
  opt :mysqlport, "Port of mysql DB", :type => :string, :default => "3306"
  opt :mysqldb, "Name of mysql DB to backup", :type => :string
  opt :mysqldumpopts, "Additional command line options for mysqldump", :type => :string
  opt :backupname, "Name of mysqlbackup. Default => dbname_yyyymmddThhmmss.sql.bak", :type => :string
  opt :backupdir, "Directory backup will be written to.", :type => :string, :default => '/var/lib/mysqlbackup' 
end

log = Logger.new(STDOUT)
log.level = Logger::INFO

abort("Backup Directory does not exist: #{opts[:backupdir]}") if not Dir.exist?(opts[:backupdir])

opts[:backupname] = "#{opts[:mysqldb]}_#{DateTime.now.strftime('%Y%m%dT%H%M%S')}.sql.bak" if not opts[:backupname]
backupPath = "#{opts[:backupdir]}/#{opts[:backupname]}"
cmd = "mysqldump #{opts[:mysqldumpopts]} -h#{opts[:mysqlhost]} -P#{opts[:mysqlport]} -u#{opts[:mysqluser]} -p#{opts[:mysqlpass]} #{opts[:mysqldb]} > #{backupPath}"

# Capture the stdout, stderr, and status of mysqldump
startTime = Process.clock_gettime(Process::CLOCK_MONOTONIC)
log.info("Database Backup Started: #{opts[:mysqldb]} to #{backupPath}\n\tCommand executed: #{cmd}")
stdout, stderr, status = Open3.capture3(cmd)
endTime = Process.clock_gettime(Process::CLOCK_MONOTONIC)
duration = endTime - startTime
File.exists?(backupPath) ? backupSize = File.size("#{opts[:backupdir]}/#{opts[:backupname]}") : backupSize = 0
log.info("Database backup Completed: #{opts[:mysqldb]}\n\tDuration: #{duration}s\n\tSuccess: #{status.success?}\n\tSize: #{backupSize}")

log.error(stderr) if not stderr.empty?

# Instantiate a Zabbix Sender Batch object and add data to it
batch = Zabbix::Sender::Batch.new(hostname: opts[:zabhost])
batch.addItemData(key: 'mysql.backupDuration', value: duration)
batch.addItemData(key: 'mysql.exitStatus', value: status.exitstatus)
batch.addItemData(key: 'mysql.backupSize', value: backupSize)
sender = Zabbix::Sender::Pipe.new
log.info(sender.sendBatchAtomic(batch))
