#!/usr/bin/env ruby

# Terminator3, Efrain Olivares.  Based on Ryan Cragun's terminator adaptation.  This version adds generation of table reports.
# v below is the original comments from Ryan's version v
# Terminator2, Ryan Cragun
# Inspired by the original Terminator by Rob Carr
# Finds and terminates servers and server arrays within a RightScale account based on passed parameters.
# Should be run as a cron daemon at least hourly.
# Requires rest_connection gem to be pre-configured with RightScale credentials.

require 'rubygems'
require 'rest_connection'
require 'time'
require 'getoptlong'
require 'terminal-table'


# Define usage
def usage
  puts("#{$0} -h <hours> [-w <safe word> -d -i <minimum server id> -m <email destination>]")
  puts("    -h: The number of hours to use for threshold")
  puts("    -w: Safe word that prevents a server from being shut down.  Required to be in nickname")
  puts("    -d: Enables debug logging")
  puts("    -i: Sets the minimum server ID that we'll check")
  puts("    -m: Recipient email address to send termination notifications to")
  puts("    -a: Account ID you wish to parse")
  exit
end

#Define default parameters
terminate_after_hours = nil
protection_word = "save"
debug = false
start_time = Time.now
current_time = Time.now
tag_prefix = "terminator:discovery_time="
min_id = 830000 # We wont check servers that have an ID lesser than this
termination_email = "terminator@rightscale.com"
account_id=nil

#Define options
opts = GetoptLong.new(
  [ '--hours', '-h', GetoptLong::REQUIRED_ARGUMENT ],
  [ '--safeword', '-w',  GetoptLong::OPTIONAL_ARGUMENT ],
  [ '--debug', '-d',  GetoptLong::OPTIONAL_ARGUMENT ],
  [ '--id', '-i',  GetoptLong::OPTIONAL_ARGUMENT ],
  [ '--mailto', '-m',  GetoptLong::OPTIONAL_ARGUMENT ],
  [ '--account', '-a', GetoptLong::OPTIONAL_ARGUMENT ]
)

opts.each do |opt, arg|
  case opt
    when '--hours'
      terminate_after_hours = arg.to_i
    when '--debug'
      debug = true
    when '--safeword'
      protection_word = arg
    when '--id'
      min_id = arg.to_i
    when '--mailto'
      termination_email = arg
    when '--account'
      account_id= arg.to_i
  end
  arg.inspect
end

puts "Debug is ON" if debug

# Throw usage warning if hour parameter is missing.
usage unless terminate_after_hours

# Set account ID if it was passed
Server.connection.settings[:api_url] = "https://my.rightscale.com/api/acct/#{account_id}" if account_id

#rows for table format summary
rows = []
total_servers = 0
total_servers_stopped = 0
total_servers_stranded = 0
total_servers_operational = 0


# Main
@servers = Server.find_all #.select { |x| x.state != "booting"}
@servers.each do |svr|

  total_servers = total_servers + 1
  
  server_state = svr.state.to_s
  case server_state
    when "operational"
     total_servers_operational = total_servers_operational + 1
    when "stopped"
     total_servers_stopped = total_servers_stopped + 1
    when "stranded in booting"
     total_servers_stranded = total_servers_stranded + 1
  end



  if svr.nickname.downcase.include?(protection_word)
    puts "Has #{protection_word} in name: NEXT" if debug
    rows << [total_servers.to_s, svr.nickname.to_s, server_state, "ON", "--", "--", "--"]
    next
  end

  if svr.nickname.downcase.include?("virtualmonkey")
    puts "Has virtualmonkey in name: NEXT" if debug
    rows << [total_servers.to_s, svr.nickname.to_s, server_state, "VMK", "--", "--", "--"]
    next
  end

  server_id =  svr.href.split("/").last.to_i
  puts "\nServer #{server_id} was processed\n" if debug
  if server_id < min_id
    puts "#{svr.href.split("/").last.to_i} is less than cutoff ID #{min_id}" if debug
    rows << [total_servers.to_s, svr.nickname.to_s, server_state, "off", server_id, "--", "--"]
    next
  end

begin  #begin attempt to catch error that forces script to exit

  settings = svr.settings
  if settings['locked'].to_s == "true"
    puts "It is LOCKED" if debug
    rows << [total_servers.to_s, svr.nickname.to_s, server_state, "off", server_id, "locked", "--"]
    next
  end

  if (start_time.year != Time.parse(settings['updated_at'].to_s).year)
    puts "#{start_time.year} != #{Time.parse(settings['updated_at'].to_s).year} : Skipping" if debug
    rows <<  [total_servers.to_s, svr.nickname.to_s, server_state, "off", server_id, "unlocked", "out of date"]
    next
  end

rescue  #if we catch the error, let's just log the name and exception and move on
  rows << [total_servers.to_s, svr.nickname.to_s, server_state,  "off", "above", "--", "EXCEPTION CAUGHT"]
  puts "\nServer #{server_id} threw an exeption, rescuing, next..\n" if debug
  next
end


  current_href = svr.current_instance_href
  matched_tag = false
  tag_timestamp = nil

  if svr.state.to_s == "stopped"
    next_tags = Tag.search_by_href(svr.href)
    next_tags.each do |tag|
      if tag['name'].include?(tag_prefix) && svr.state.to_s == "stopped"
        Tag.unset(svr.href,[tag['name'].to_s])
        puts "Deleting tag: \"#{tag['name'].to_s}\" on stopped server" if debug
      end
    end
  else
    current_tags = Tag.search_by_href(current_href)
    current_tags.each do |tag|
      if svr.state.to_s == "operational" && tag['name'].to_s.include?(tag_prefix)
        tag_timestamp = Time.parse(tag['name'].split("=").last)
        matched_tag = true
        puts "Found matching tag: \"#{tag['name'].to_s} on #{svr.nickname.to_s}" if debug
        break
      end
    end
  end 
      
  unless matched_tag || svr.state.to_s == "stopped"
    tag_contents = [tag_prefix + current_time.to_s]
    puts "No tag found for: \"#{svr.nickname.to_s}\", setting tag now..." if debug
    Tag.set(current_href, tag_contents)
    rows << [total_servers.to_s, svr.nickname.to_s, server_state,  "off", server_id, "unlocked", "No tag, setting now"]
 end

  if matched_tag
    if svr.cloud_id.to_i  != 1
      puts "Server not on cloud region 1: Skipping" if debug 
      rows << [total_servers.to_s, svr.nickname.to_s, server_state,  "off", server_id, "unlocked", "Not on 1"]
      next
    end
    life_time = tag_timestamp + (terminate_after_hours * 60 * 60) 
    current_time = Time.now
    if (current_time > life_time)
      puts "Tag found on #{svr.nickname} is older than the allowable time.."
      puts "Terminating => #{svr.nickname}..\n"
      rows << [total_servers.to_s,svr.nickname.to_s, server_state,  "off", server_id, "unlocked", "TERMINATING"]
      svr.stop
      `echo 'Be sure to lock the server or put "save" somewhere in the nickname to prevent pwnage from the terminator' | mail -s "#{svr.nickname} has been destroyed by the Terminator2901." #{termination_email}`
    else
      rows << [total_servers.to_s, svr.nickname.to_s, server_state,  "off", server_id, "unlocked", life_time - (8 * 60 * 60) ]
      puts "Tag found is within allowable range, skipping server.."
    end
 end
end

@arrays = Ec2ServerArray.find_all.select { |a| a.active_instances_count != 0 }
@arrays.each do |ary|
  next if ary.nickname.downcase.include?(protection_word) || ary.cloud_id != nil # We don't want to operate on non-ec2 clouds with API 1.0
  @flagged_instances = 0
  instances = ary.instances
  instances.each do |inst|
    #discover instance tags
    matched_tag = nil
    local_tags = Tag.search_by_href(inst['href'])
    #check for a match
    local_tags.each do |tag|
      if tag['name'].include?(tag_prefix)
        matched_tag = tag['name'].to_s
        puts "Found matching tag #{matched_tag} on #{inst['nickname']}" if debug
      end
    end
    #set terminator tag if no match exists
    if matched_tag == nil
      tag_contents = [tag_prefix + current_time.to_s]
      Tag.set(inst['href'], tag_contents)
      puts "No tag found for instance #{inst['nickname']}, setting tag now..." if debug
    end
    #compare timestammps for a match and flag the server if it's too old
    if matched_tag != nil
      tag_timestamp = Time.parse(matched_tag.split("=").last)
      life_time = tag_timestamp + (terminate_after_hours * 60 * 60) 
      if (current_time > life_time)
        @flagged_instances += 1
        puts "Instance #{inst['nickname']} flagged for age.." if debug
      end
    end 
  end
  puts "Flagged instance count: #{@flagged_instances}"
  puts "Active instance count: #{ary.active_instances_count.to_s}"
  if (@flagged_instances >= (ary.active_instances_count.to_f / 2))
    puts "Terminatation initiated.."
    ary.active = false
    ary.save
    ary.terminate_all
    puts "Terminating => #{ary.nickname}\n"
    `echo 'The array was disabled and all instances were terminated because at least 50% of the active instances were at least 24 hours old.  To prevent this please put "save" in the array nickname' | mail -s "The #{ary.nickname} has been disabled and all instances have been destroyed by the Terminator." #{termination_email}`
  end
end

 
table = Terminal::Table.new :rows => rows 
theTOTALS = "TOTAL: #{total_servers}\nOperational: #{total_servers_operational}\nStranded: #{total_servers_stranded}\nStopped: #{total_servers_stopped}"
table.headings = [theTOTALS, "Nickname", "Status", "Safety", "ID range", "Lock", "Termination time"]
#puts table
file = File.open("tableReport.txt", "w")
file.puts table

time_taken = ((Time.now - start_time)/60)
puts "Total time taken was: #{time_taken} minutes"
