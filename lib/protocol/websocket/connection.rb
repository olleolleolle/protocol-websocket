# Copyright, 2019, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require_relative 'framer'
require 'securerandom'

module Protocol
	module WebSocket
		class Connection
			# @option mask [String] 4-byte mask to be used for frames generated by this connection.
			def initialize(framer, mask: nil)
				if mask == true
					mask = SecureRandom.bytes(4)
				end
				
				@framer = framer
				@mask = mask
				
				@state = :open
				@frames = []
			end
			
			# The framer which is used for reading and writing frames.
			attr :framer
			
			# The (optional) mask which is used when generating frames.
			attr :mask
			
			# Buffered frames which form part of a complete message.
			attr_accessor :frames
			
			def flush
				@framer.flush
			end
			
			def closed?
				@state == :closed
			end
			
			def close
				send_close unless closed?
				
				@framer.close
			end
			
			def read_frame
				return nil if closed?
				
				frame = @framer.read_frame
				
				yield frame if block_given?
				
				frame.apply(self)
				
				return frame
			rescue ProtocolError => error
				send_close(error.code, error.message)
				
				raise
			rescue
				send_close(Error::PROTOCOL_ERROR, $!.message)
				
				raise
			end
			
			def write_frame(frame)
				@framer.write_frame(frame)
			end
			
			def receive_text(frame)
				if @frames.empty?
					@frames << frame
				else
					raise ProtocolError, "Received text, but expecting continuation!"
				end
			end
			
			def receive_binary(frame)
				if @frames.empty?
					@frames << frame
				else
					raise ProtocolError, "Received binary, but expecting continuation!"
				end
			end
			
			def receive_continuation(frame)
				if @frames.any?
					@frames << frame
				else
					raise ProtocolError, "Received unexpected continuation!"
				end
			end
			
			def send_text(buffer)
				frame = TextFrame.new(mask: @mask)
				frame.pack buffer
				
				write_frame(frame)
			end
			
			def send_binary(buffer)
				frame = BinaryFrame.new(mask: @mask)
				frame.pack buffer
				
				write_frame(frame)
			end
			
			def send_close(code = Error::NO_ERROR, message = nil)
				frame = CloseFrame.new(mask: @mask)
				frame.pack(code, message)
				
				self.write_frame(frame)
				self.flush
				
				@state = :closed
			end
			
			def receive_close(frame)
				@state = :closed
				
				code, message = frame.unpack
				
				if code and code != Error::NO_ERROR
					raise ClosedError.new message, code
				end
			end
			
			def send_ping(data = "")
				if @state != :closed
					frame = PingFrame.new(mask: @mask)
					frame.pack(data)
					
					write_frame(frame)
				else
					raise ProtocolError, "Cannot send ping in state #{@state}"
				end
			end
			
			def open!
				@state = :open
				
				return self
			end
			
			def receive_ping(frame)
				if @state != :closed
					write_frame(frame.reply)
				else
					raise ProtocolError, "Cannot receive ping in state #{@state}"
				end
			end
			
			def receive_pong(frame)
				# Ignore.
			end
			
			def receive_frame(frame)
				warn "Unhandled frame #{frame.inspect}"
			end
			
			# @param buffer [String] a unicode or binary string.
			def write(buffer)
				# https://tools.ietf.org/html/rfc6455#section-5.6
				
				# Text: The "Payload data" is text data encoded as UTF-8
				if buffer.encoding == Encoding::UTF_8
					send_text(buffer)
				else
					send_binary(buffer)
				end
			end
			
			# @return [String] a unicode or binary string.
			def read
				@framer.flush
				
				while read_frame
					if @frames.last&.finished?
						buffer = @frames.map(&:unpack).join
						@frames = []
						
						return buffer
					end
				end
			end
			
			# Deprecated.
			def next_message
				@framer.flush
				
				while read_frame
					if @frames.last&.finished?
						frames = @frames
						@frames = []
						
						return frames
					end
				end
			end
		end
	end
end
