#!/usr/bin/env ruby

require 'xmmsclient'
require 'gtk2'

def debug(*arg)
  puts(*arg)
end

class Interact
  include Singleton

  def initialize()
    begin
      @xc = Xmms::Client.new('Rater').connect(ENV['XMMS_PATH'])
    rescue Xmms::Client::ClientError
      puts 'Failed to connect to XMMS2 daemon.'
      puts 'Please make sure xmms2d is running and using the correct IPC path.'
      exit
    end
  end

  def method_missing(method, *args, &block)
    @xc.send(method, *args, &block)
  end
end


