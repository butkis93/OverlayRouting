require 'base64'

require_relative 'control_msg_packet.rb'

#Handles Control Message Packets (CMPs) from the CMP queue
#Functions might return packets to add to forward_queue
class ControlMessageHandler


	def self.handle(main_processor, control_message_packet, optional_args=Hash.new)
		$log.debug "Processing #{control_message_packet.inspect}"
		payload = control_message_packet.payload

		cmp_type = control_message_packet.type

		if cmp_type.eql? "TRACEROUTE"
			self.handle_traceroute_cmp(main_processor, control_message_packet, optional_args)
		elsif cmp_type.eql? "FTP"
			self.handle_ftp_cmp(main_processor, control_message_packet, optional_args)
		elsif cmp_type.eql? "SND_MSG"
			self.handle_send_message_cmp(main_processor, control_message_packet, optional_args)
		else
			$log.warn "Control Message Type: #{cmp_type} not handled"
		end
			
	end

	#Handle a traceroute message 
	def self.handle_traceroute_cmp(main_processor, control_message_packet, optional_args)
		#A traceroute message is completed when payload["complete"] is true
		#and payload["original_source_name"] == main_processor.source_hostname
		#In that case payload["traceroute_data"] will have our data

		#TODO handle timeouts

		payload = control_message_packet.payload

		if payload["complete"]
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				$log.debug "Traceroute arrived back #{payload.inspect}"
				puts payload["data"]
			else
				#Else data is complete. It is just heading back to original source
				return control_message_packet, {}
			end
			
		else
			#Get difference between last hop time and current time in milliseconds
			hop_time = (main_processor.node_time * 1000).to_i - payload["last_hop_time"].to_i
			hop_time.ceil

			#Update hop time on payload in ms
			payload["last_hop_time"] = hop_time

			#Update hopcount
			payload["HOPCOUNT"] = payload["HOPCOUNT"].to_i + 1

			payload["data"] += "#{payload["HOPCOUNT"]} #{main_processor.source_hostname} #{hop_time}\n"

			#Trace Route has reached destination. Send a new packet to original
			#source with the same data but marked as completed
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				payload["complete"] = true
				control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
				main_processor.source_ip, control_message_packet.source_name,
				control_message_packet.source_ip, 0, "TRACEROUTE", payload, main_processor.node_time)

			end

			control_message_packet.payload = payload
			return control_message_packet, {}
		
		end

	end

	#Handle a ftp message 
	def self.handle_ftp_cmp(main_processor, control_message_packet, optional_args)
		#TODO handle fragmented packets later
		#TODO handle partial data received

		payload = control_message_packet.payload

		unless control_message_packet.destination_name.eql? main_processor.source_hostname
			#packet is not for this node and we have nothing to add. Just forward it along.
			return control_message_packet, {}
		end

		if payload["failure"]
			puts "FTP: ERROR: #{payload["file_name"]} --> #{control_message_packet.source_name} INTERRUPTED AFTER #{payload["bytes_written"]}"
		elsif payload["complete"]
			#TODO handle Returned FTP complete. Packet back at source to handle
			$log.debug "TODO FTP packet arrived back #{payload.inspect}"

			#Calculate seconds since initial FTP packet
			time = main_processor.node_time.to_f - control_message_packet.time_sent
			time = time.ceil

			speed = 0
			begin
				speed = (payload["size"].to_i / time).floor
			rescue Exception => e
				throw e #TODO delete
				#probably a 0 as time just use 0 as the speed then
			end

			puts "FTP: #{payload["file_name"]} --> #{control_message_packet.source_name} in #{time} at #{speed}"
			return nil, {} # no packet to forward
		else
			begin
				file_path = payload["FPATH"] + '/' + payload["file_name"]

				file_exists = File.exists? file_path

				begin
					file = File.open(file_path, "w+b:ASCII-8BIT")
					file.print Base64.decode64(payload["data"])
				rescue Exception => e
					#if file existed before attempted write don't delete
					unless file_exists
						File.delete file_path
						$log.info "deleted #{file_path} since FTP failed"
					end
					throw e
				end

				if file
					bytes_written = file.size
				else
					bytes_written = 0
				end

				file.close

				unless bytes_written.eql? payload["size"]
					#TODO I don't think this can happen when we do fragmentation
					throw "FTP size mismatch. Payload size: #{payload["size"]} != bytes_written: #{bytes_written}"
				end

				payload["complete"] = true
				payload.delete "data" #clear data

				#Create new control message packet to send back to source but preserve original node time
				control_message_packet = ControlMessagePacket.new(control_message_packet.destination_name,
				control_message_packet.destination_ip, control_message_packet.source_name,
				control_message_packet.source_ip, 0, "FTP", payload, control_message_packet.time_sent)

				puts "FTP: #{control_message_packet.source_name} --> #{file_path}"

				control_message_packet.payload = payload
				return control_message_packet, {}

			rescue Exception => e

				$log.debug "FTP Exception #{e.inspect}"
				puts "FTP: ERROR: #{control_message_packet.source_name} --> #{file_path}"

				payload["complete"] = false
				payload["failure"] = true
				payload.delete "data" #clear data

				payload["bytes_written"] = 0 #TODO handle partial data

				#Create new control message packet to send back to source but preserve original node time
				control_message_packet = ControlMessagePacket.new(control_message_packet.destination_name,
				control_message_packet.destination_ip, control_message_packet.source_name,
				control_message_packet.source_ip, 0, "FTP", payload, control_message_packet.time_sent)

				return control_message_packet, {}
			end
		end
	end

	# -----------------------------------------------------------
	# Reconstructs a control message packet according to the
	# current node that it is on. Returns nil if the packet has
	# gotten back to its origin, otherwise it returns the
	# changed control message packet.
	# -----------------------------------------------------------
	def self.handle_send_message_cmp(main_processor, control_message_packet, optional_args)
		payload = control_message_packet.payload

		if payload["complete"]
			# if the packet has made a round trip, determine if it was a success or
			# not and print the corresponding messages
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				if payload["failure"]
					$log.debug "SendMessage got back to the source but failed to fully send to recipient, payload: #{payload.inspect}"
					puts "SENDMSG ERROR: #{control_message_packet.source_name} UNREACHABLE"
				end
			else
				# hasn't gotten back to source yet, so return packet so that it'll be forwarded
				return control_message_packet, {}
			end
		else
			# arrived at the destination, send back to source node so that the source can 
			# confirm if the message was fully received by inspecting the presence of
			# the failure key in the payload hash
			if control_message_packet.destination_name.eql? main_processor.source_hostname
				if payload["size"].to_i != payload["message"].size
					payload["failure"] = true
				else
					$log.debug "SendMessage got to the destination successfully, payload: #{payload.inspect}"
					puts("SENDMSG: #{control_message_packet.source_name} --> " + payload["message"])
				end

				payload["complete"] = true
				control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
				main_processor.source_ip, control_message_packet.source_name,
				control_message_packet.source_ip, 0, "SND_MSG", payload, main_processor.node_time)
			end

			control_message_packet.payload = payload
			return control_message_packet, {}
		end
	end

	# ------------------------------------------------------------------------------
	# This method will be used to handle advertise control message packets.
	# It will propagate the message on to the next node it needs to go to while
	# keeping track of the node it need to travel to next and the one it came 
	# from. Each node will contain a table to keep track of all the nodes in the
	# subscription. The key is the subscription id and the value is the list of
	# nodes in the subscription.
	# ------------------------------------------------------------------------------
	def self.handle_advertise(main_processor, control_message_packet, optional_args)
		destination_count = 0
		payload = control_message_packet.payload

		unless control_message_packet.destination_name.eql? main_processor.source_hostname
			#packet is not for this node and we have nothing to add. Just forward it along.
			return control_message_packet, {}
		end

		if payload["complete"]
			# Check if subscription is already in the table
			if main_processor.subscription_table.include?(payload["unique_id"])
				puts "ADVERTISE #{payload["unique_id"]}: CONSISTENCY FAULT #{main_processor.first_subscription_node_table[payload["unique_id"]]} ¿¿ #{payload["current"]}"
				return nil
			end

			# Not in table first node that the packet came on
			main_processor.subscription_table[payload["unique_id"]] = payload["node_list"]
			main_processor.first_subscription_node_table[payload["unique_id"]] = payload["current"]

			log.debug "Added subscription to subscription table: #{payload["unique_id"]} #{main_processor.subscription_table}"

			puts "#{payload["node_list"].length} NODES #{payload["node_list"]} SUBSCRIBED TO #{payload["unique_id"]}"
			return nil
		else

			# Add unique id to subscription table in the main processor
			main_processor.subscription_table[payload["unique_id"]] = payload["node_list"]

			# Add current node to visited node list
			payload["visited"] << main_processor.source_name

			# Record prev and current 
			payload["prev"] = payload["current"]
			payload["current"] = main_processor.source_hostname

			# Check if the message has reach every node in the 
			# ndoe list
			if payload["visited"].length == payload["node_list"].length

				# Record next node
				payload["next"] = control_message_packet.source_name

				payload["complete"] = true
				control_message_packet = ControlMessagePacket.new(main_processor.source_hostname,
					main_processor.source_ip, control_message_packet.source_name,
					control_message_packet.source_ip, 0, "ADVERTISE", payload, main_processor.node_time)

				$log.debug "ADVERTISE heading back to source"

				# Produce output for going back to source
				puts "ADVERTISE: #{payload["unique_id"} #{payload["prev"]} --> #{payload["next"]}"
			else
				until !payload["node_list"][destination_count].eql?(main_processor.source_name) 
					&& !payload["visited"].include?(payload["node_list"][destination_count])
					destination_count += 1
				end

				# Recored next node
				payload["next"] = payload["node_list"][destination_count]

				control_message_packet = ControlMessagePacket.new(control_message_packet.source_hostname,
					control_message_packet.source_ip, payload["node_list"][destination_count], 
					nil, 0, "ADVERTISE", payload, main_processor.node_time)

				$log.debug "ADVERTISE heading to #{payload["next"] came from payload["prev"]}"
				
				# Produce output for going to next
				puts "ADVERTISE: #{payload["unique_id"} #{payload["prev"]} --> #{control_message_packet.source_name}"

			end

			control_message_packet.payload = payload
			return control_message_packet, {}			
		end
	end
end