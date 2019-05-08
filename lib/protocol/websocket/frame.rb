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

require_relative 'error'

module Protocol
	module WebSocket
		class Frame
			include Comparable
			
			# Opcodes
			CONTINUATION = 0x0
			TEXT = 0x1
			BINARY = 0x2
			CLOSE = 0x8
			PING = 0x9
			PONG = 0xA
			
			# @param length [Integer] the length of the payload, or nil if the header has not been read yet.
			def initialize(fin = true, opcode = 0, mask = nil, payload = nil)
				@fin = fin
				@opcode = opcode
				@mask = mask
				@length = payload&.bytesize
				@payload = payload
			end
			
			def self.read(stream)
				frame = self.new
				
				if frame.read(stream)
					return frame
				end
			rescue EOFError
				return nil
			end
			
			def <=> other
				to_ary <=> other.to_ary
			end
			
			def to_ary
				[@fin, @opcode, @mask, @length, @payload]
			end
			
			def control?
				@opcode & 0x8
			end
			
			def continued?
				@fin == false
			end
			
			# The generic frame header uses the following binary representation:
			#
			#  0                   1                   2                   3
			#  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
			# +-+-+-+-+-------+-+-------------+-------------------------------+
			# |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
			# |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
			# |N|V|V|V|       |S|             |   (if payload len==126/127)   |
			# | |1|2|3|       |K|             |                               |
			# +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
			# |     Extended payload length continued, if payload len == 127  |
			# + - - - - - - - - - - - - - - - +-------------------------------+
			# |                               |Masking-key, if MASK set to 1  |
			# +-------------------------------+-------------------------------+
			# | Masking-key (continued)       |          Payload Data         |
			# +-------------------------------- - - - - - - - - - - - - - - - +
			# :                     Payload Data continued ...                :
			# + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
			# |                     Payload Data continued ...                |
			# +---------------------------------------------------------------+
			
			attr_accessor :fin
			attr_accessor :opcode
			attr_accessor :mask
			attr_accessor :length
			attr_accessor :payload
			
			def unpack
				@payload
			end
			
			def pack(payload)
				@payload = payload
				@length = payload.bytesize
				
				if @length.bit_length > 64
					raise ProtocolError, "Frame length #{@length} bigger than allowed 64-bit field!"
				end
			end
			
			def read(stream)
				buffer = stream.read(2) or raise EOFError
				first, second = buffer.unpack("CC")
				
				@fin = (first & 0b1000_0000 != 0)
				# rsv = byte & 0b0111_0000
				@opcode = first & 0b0000_1111
				
				@mask = (second & 0b1000_0000 != 0)
				@length = second & 0b0111_1111
				
				if @length == 126
					buffer = stream.read(2) or raise EOFError
					@length = buffer.unpack('n').first
				elsif @length == 127
					buffer = stream.read(4) or raise EOFError
					@length = buffer.unpack('Q>').first
				end
				
				if @mask
					@mask = stream.read(4) or raise EOFError
					@payload = read_mask(@mask, @length, stream)
				else
					@mask = nil
					@payload = stream.read(@length) or raise EOFError
				end
				
				if @payload&.bytesize != @length
					raise ProtocolError, "Invalid payload size: #{@length} != #{@payload.bytesize}!"
				end
				
				return true
			end
			
			def write(stream)
				buffer = String.new.b
				
				if @payload&.bytesize != @length
					raise ProtocolError, "Invalid payload size: #{@length} != #{@payload.bytesize}!"
				end
				
				if @mask and @mask.bytesize != 4
					raise ProtocolError, "Invalid mask length!"
				end
				
				if length <= 125
					short_length = length
				elsif length.bit_length <= 16
					short_length = 126
				else
					short_length = 127
				end
				
				buffer << [
					(@fin ? 0b1000_0000 : 0) | @opcode,
					(@mask ? 0b1000_0000 : 0) | short_length,
				].pack('CC')
				
				if short_length == 126
					buffer << [@length].pack('n')
				elsif short_length == 127
					buffer << [@length].pack('Q>')
				end
				
				if @mask
					buffer << @mask
					write_mask(@mask, @payload, buffer)
					stream.write(buffer)
				else
					stream.write(buffer)
					stream.write(@payload)
				end
			end
			
			private
			
			def read_mask(mask, length, stream)
				data = stream.read(length) or raise EOFError
				
				for i in 0...data.bytesize do
					data.setbyte(i, data.getbyte(i) ^ mask.getbyte(i % 4))
				end
				
				return data
			end
			
			def write_mask(mask, data, buffer)
				for i in 0...data.bytesize do
					buffer << (data.getbyte(i) ^ mask.getbyte(i % 4))
				end
			end
		end
	end
end
