#!/usr/bin/env ruby


require 'pry-byebug'
require 'zabbix_sender_api'
require 'optimist'
require 'benchmark'
require 'date'
require 'logging'
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
  opt :tab, "Backup database to individual tables using --tab parameter. Uses :backupname if True", :default => false
  opt :'include-tables', "Space-delimited list of tables to include in backup.", :type => :string
  opt :backupname, "Name of mysqlbackup. Always starts with yyyymmddThhmmss_mysqldb_", :type => :string
  opt :backupdir, "Directory backup will be written to.", :type => :string, :default => '/var/lib/mysqlbackup' 
  opt :pruneolderthan, "Deletes backups older than number of days specified.", :type => :integer
  opt :cstream, "Use cstream to manage IO load to the bps specified here.", :type => :integer, :required => false
  opt :loglevel, "Set logging level", :type => :string, :default => "info"
end

log = Logging.logger(STDOUT)
log.level = opts[:loglevel].to_sym

abort("Backup Directory does not exist: #{opts[:backupdir]}") if not Dir.exist?(opts[:backupdir])
backupDbName = "#{opts[:mysqldb]}_#{opts[:backupname]}"
backupName = opts[:backupname] ? "#{DateTime.now.strftime('%Y%m%dT%H%M%S')}_#{backupDbName}" : "#{DateTime.now.strftime('%Y%m%dT%H%M%S')}_#{opts[:mysqldb]}"
backupPath = "#{opts[:backupdir]}/#{backupName}.sql"

if opts[:tables]
  cmd = "mysqldump #{opts[:mysqldumpopts]} --tab #{opts[:backupdir]}/#{backupName} -h#{opts[:mysqlhost]} -P#{opts[:mysqlport]} -u#{opts[:mysqluser]} -p#{opts[:mysqlpass]} #{opts[:mysqldb]}"
  log.info("Creating directory #{opts[:backupdir]}/#{backupName}")
  FileUtils.mkdir_p "#{opts[:backupdir]}/#{backupName}"
else
  cmd = "mysqldump #{opts[:mysqldumpopts]} -h#{opts[:mysqlhost]} -P#{opts[:mysqlport]} -u#{opts[:mysqluser]} -p#{opts[:mysqlpass]} #{opts[:mysqldb]}"
  cmd += opts[:'include-tables'].nil? ? nil.to_s : " #{opts[:'include-tables']}"
  # should do sanity checking on cstream, including calling absolute path
  cmd += opts[:cstream].nil? ? nil.to_s : " | cstream -t #{opts[:cstream]}"
  cmd += " > #{backupPath}"
end
# Capture the stdout, stderr, and status of mysqldump
startTime = Process.clock_gettime(Process::CLOCK_MONOTONIC)
log.info("Database Backup Started: #{opts[:mysqldb]} to #{backupPath}\n\tCommand executed: #{cmd}")
stdout, stderr, status = Open3.capture3(cmd)
endTime = Process.clock_gettime(Process::CLOCK_MONOTONIC)
duration = endTime - startTime
backupSize = File.exists?(backupPath) ? File.size(backupPath) : 0
log.info("Database backup Completed: #{opts[:mysqldb]}\n\tDuration: #{duration}s\n\tSuccess: #{status.success?}\n\tSize: #{backupSize}")

log.error(stderr) if not stderr.empty?

backupsPruned = 0
if opts[:pruneolderthan]
  beforePrune = Dir.glob("#{opts[:backupdir]}\/*_#{backupDbName}.sql")
  toPrune = beforePrune.select {|f| 
    File.mtime(f).to_datetime < DateTime.now - opts[:pruneolderthan]
  }
  log.info("Found #{toPrune.count} backups older than #{opts[:pruneolderthan]} days to prune")
  toPrune.each {|f|
    log.debug("\tRemoving: #{f}")
    FileUtils.rm(f, verbose: true) if not opts[:tables] # Delete files if not using --tab
    FileUtils.rm_r(f, verbose: true) if opts[:tables] # Delete directories if using --tab
  }

  afterPrune = Dir.glob("#{opts[:backupdir]}\/*_#{backupDbName}.sql")
  backupsPruned = beforePrune.count - afterPrune.count
  log.warn("Pruned backups is not the same as what should have been pruned: toPrune: #{toPrune.count}\tbackupsPruned: #{backupsPruned}") if toPrune.count != backupsPruned
  log.debug("Pruned #{backupsPruned} backups")
end

# Instantiate a Zabbix Sender Batch object and add data to it
batch = Zabbix::Sender::Batch.new(hostname: opts[:zabhost])
batch.addItemData(key: 'mysql.backupDuration', value: duration)
batch.addItemData(key: 'mysql.exitStatus', value: status.exitstatus)
batch.addItemData(key: 'mysql.backupSize', value: backupSize)
batch.addItemData(key: 'mysql.backupsPruned', value: backupsPruned.to_i)
sender = Zabbix::Sender::Pipe.new(proxy: opts[:zabproxy])
log.debug(batch.to_senderline)
log.info(sender.sendBatchAtomic(batch))
