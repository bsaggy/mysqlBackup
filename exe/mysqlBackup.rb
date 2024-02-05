#!/usr/bin/env ruby


require 'pry-byebug'
require 'zabbix_sender_api'
require 'optimist'
require 'benchmark'
require 'date'
require 'logger'
require 'fileutils'

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
  opt :tables, "Backup database to individual tables using --tab parameter. Uses :backupname if True", :default => false
  opt :backupname, "Name of mysqlbackup. Default => dbname_yyyymmddThhmmss", :type => :string
  opt :backupdir, "Directory backup will be written to.", :type => :string, :default => '/var/lib/mysqlbackup' 
  opt :pruneolderthan, "Deletes backups older than number of days specified.", :type => :integer
end

log = Logger.new(STDOUT)
log.level = Logger::INFO

abort("Backup Directory does not exist: #{opts[:backupdir]}") if not Dir.exist?(opts[:backupdir])

opts[:backupname] = "#{opts[:mysqldb]}_#{DateTime.now.strftime('%Y%m%dT%H%M%S')}" if not opts[:backupname]
backupPath = "#{opts[:backupdir]}/#{opts[:backupname]}.sql.bak"
if opts[:tables]
  cmd = "mysqldump #{opts[:mysqldumpopts]} --tab #{opts[:backupdir]}/#{opts[:backupname]} -h#{opts[:mysqlhost]} -P#{opts[:mysqlport]} -u#{opts[:mysqluser]} -p#{opts[:mysqlpass]} #{opts[:mysqldb]}"
  puts "Creating directory #{opts[:backupdir]}/#{opts[:backupname]}"
  FileUtils.mkdir_p "#{opts[:backupdir]}/#{opts[:backupname]}"
else
  cmd = "mysqldump #{opts[:mysqldumpopts]} -h#{opts[:mysqlhost]} -P#{opts[:mysqlport]} -u#{opts[:mysqluser]} -p#{opts[:mysqlpass]} #{opts[:mysqldb]} > #{backupPath}"
end
# Capture the stdout, stderr, and status of mysqldump
startTime = Process.clock_gettime(Process::CLOCK_MONOTONIC)
log.info("Database Backup Started: #{opts[:mysqldb]} to #{backupPath}\n\tCommand executed: #{cmd}")
stdout, stderr, status = Open3.capture3(cmd)
endTime = Process.clock_gettime(Process::CLOCK_MONOTONIC)
duration = endTime - startTime
File.exists?(backupPath) ? backupSize = File.size("#{opts[:backupdir]}/#{opts[:backupname]}") : backupSize = 0
log.info("Database backup Completed: #{opts[:mysqldb]}\n\tDuration: #{duration}s\n\tSuccess: #{status.success?}\n\tSize: #{backupSize}")

log.error(stderr) if not stderr.empty?

backupsPruned = 0
if opts[:pruneolderthan]
  beforePrune = Dir.glob("#{opts[:backupdir]}/#{opts[:mysqldb]}*.bak").count
  log.info("Removing backups older than #{opts[:pruneolderthan]} days:")  
  Dir.glob("#{opts[:backupdir]}/*").each {|f|
    if File.mtime(f).to_datetime < DateTime.now - opts[:pruneolderthan]
      log.info("\t#{f}")
      FileUtils.rm(f, verbose: true)
    end
  }
  afterPrune = Dir.glob("#{opts[:backupdir]}/#{opts[:mysqldb]}*.bak").count
  backupsPruned = beforePrune - afterPrune
end

# Instantiate a Zabbix Sender Batch object and add data to it
batch = Zabbix::Sender::Batch.new(hostname: opts[:zabhost])
batch.addItemData(key: 'mysql.backupDuration', value: duration)
batch.addItemData(key: 'mysql.exitStatus', value: status.exitstatus)
batch.addItemData(key: 'mysql.backupSize', value: backupSize)
batch.addItemData(key: 'mysql.backupsPruned', value: backupsPruned)
sender = Zabbix::Sender::Pipe.new
log.info(sender.sendBatchAtomic(batch))
