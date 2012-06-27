$KCODE = "u"
require 'rubygems'
require 'time'
require 'pg'
require "hoptoad_notifier"
require "right_aws"

require '../app/models/user.rb'
require '../app/models/period.rb'
require '../app/models/velocity.rb'


namespace :tweets do

		

	desc "Calculates accelerations"
	task :summarize do 
	begin		
		
		
		users = {}
		total_mentions = 0
		followers = 0
		users_with_followers = 0

		
			users = Tweet.mentioned_users
			total_mentions += mentioned_users.length
			mentioned_users.each do |user|
				users[user] ||= User.find "u_#{user}"
				users[user] ||= User.new :_id => "u_#{user}", :nickname => user
				users[user].reports ||= {}
				if users[user].reports[time_key].blank?
					users[user].reports[time_key] = Hash.new 
					users[user].reports[time_key][:time] = time_key
					users[user].reports[time_key][:mentions] = 0
				end
				users[user].reports[time_key][:mentions] ||= 0
				users[user].reports[time_key][:mentions] += 1
			end
		end

		#we calculate aceleration, obtain the user, calculate velocity and store the info

		puts "sorting users"

		# Now we get a list of users sorted by the number of mentions
		top_users = {}
		users.each do |user, info|
			n_mentions = info.reports[time_key][:mentions]
			top_users[n_mentions] ||= []
			top_users[n_mentions] << user
		end

		puts "Getting Twitter Info"

		# Now we get the followers number for the most mentioned users
		api_requests = 0
		begin
			top_users.sort.reverse.each do |mentions, mentioned_users|
				mentioned_users.each do |user|
                               		unless users[user].profile.blank?
                                                puts "Not retrieving info for #{user}"
                                                followers += users[user].profile["followers_count"]
                                                users_with_followers += 1
					end
                                end
				mentioned_users.each do |user|
					begin
						if users[user].profile.blank?
							puts "Retrieving info for #{user}"
							twitter_profile = Twitter::Client.new.user(user.dup)
							users[user].profile = JSON.parse(twitter_profile.to_json)
							users[user].profile[:time] = time_query
							users[user].save
						end
						followers += users[user].profile["followers_count"] 
						users_with_followers += 1
					rescue Twitter::NotFound => ex
						puts "User not found: #{ex}"
					end
				end
			end
		rescue	Exception => ex
			puts "Twitter API LIMIT exceeded #{ex}"			
		end

		if total_mentions == 0
			puts "No mentions"
			return;
		end
		puts "Computing velocity"

		# Now, with twitter info we shoud be able to compute Phi. We need:
		# The average number of mentions per hour (for now, the mentions in this period)
		average_mentions = total_mentions
		# Number of users
		total_users = users.length
		# The average number of followers for a user (taken from the profiles just collected)
		average_followers = followers / users_with_followers.to_f
		phi = (average_mentions / total_users) / average_followers

		puts "mentions: #{average_mentions}"
		puts "users: #{total_users}"
		puts "followers: #{average_followers}"
		puts "phi: #{phi}" 	

		# And now we compute the velocity for all the users

		accelerated_users = {}
		total_acceleration = 0
		total_velocity = 0

		users.each do |user, profile|
			report = profile.reports[time_key]
			previous_time_key = profile.reports.keys.select{|k| k < time_key}.last
			previous_report = unless previous_time_key.blank?
				profile.reports[previous_time_key]
			end
			followers = (profile.profile.blank? or profile.profile["followers_count"] == 0) ? average_followers : profile.profile["followers_count"]

			report[:acceleration] = (report[:mentions] / followers.to_f) - phi
			total_acceleration += report[:acceleration]

			report[:velocity] = (previous_report.blank? ? 0 : previous_report[:velocity]||0) + (report[:acceleration] || 0)
			total_velocity += report[:velocity]

			past_report = profile.reports[2.hour.ago.strftime("%Y%m%d%H")].
			report[:previous_ranking] = past_report[:ranking] unless  past_report.blank?

			accelerated_users[report[:acceleration]] ||= []
			accelerated_users[report[:acceleration]] << {:username => user, :report => report}

		end
		puts "saving"

		period_report = PeriodReport.find(time_query) || PeriodReport.new(:_id => time_query, :time => time_query)
		period_report.mentions = total_mentions
		period_report.average_followers =  average_followers
		period_report.average_acceleration = total_acceleration / users.length
		period_report.average_velocity = total_velocity / users.length
		period_report.sorted_users = accelerated_users.sort.reverse.map{|acceleration, a_users| a_users}.flatten
		period_report.save

		users.each do |user, info| 
			report = info.reports[time_key]
			accelerations = accelerated_users.keys.select{|a| a > report[:acceleration]}
			report[:ranking] = 1
			accelerations.each do |a|
				report[:ranking] += accelerated_users[a].length
			end
			info.save 
		end
	rescue Exception => ex
		HoptoadNotifier.notify ex
		raise ex				
	end
	end

	desc "Saves tweets from the previous 30 days as a set of JSON files"
	task :archive do

		720.times do |i|
			lag = settings["archive"]["lag"]

			time_key = (lag+i).hour.ago.strftime("%Y %b %d %H") #"2011 Feb 01 19"

			puts "Getting tweets for #{time_key}"

			tweets =  Tweet.view "by_hour", :key => time_key

			puts "#{tweets.length} tweets"
			unless tweets.blank?
				puts "Archiving #{tweets.length} tweets (#{(lag+i).hour.ago.strftime("%Y%m%d%H")})"
				File.open("#{settings["archive"]["tweets_folder"]}/#{(lag+i).hour.ago.strftime("%Y%m%d%H")}", 'w') {|f| f.write(tweets.to_json) }	
				puts "Clearing tweets"
				tweets.each do |t| 
						t.destroy 
				end

			end
			puts "Done"
		end

			puts "Compacting database"
			EventMachine::run {
			  couch = EventMachine::Protocols::CouchDB.connect :host => 'localhost', :port => 5984, :database => 'twitter-stream'
			  couch.compact("tweets") do
			  	# Once we have compacted the database we can close the EventMachine loop
				EventMachine::stop_event_loop
			  end
			}

	end
end