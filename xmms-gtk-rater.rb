#!/usr/bin/env ruby

require 'xmmsclient'
require 'xmmsclient_glib'
require 'glib2'
require 'gtk2'

def debug(*arg)
  puts(*arg)
end

class XmmsInteract < DelegateClass(Xmms::Client)
  include Singleton
  def initialize()
    begin
      @xc = Xmms::Client.new('Rater').connect(ENV['XMMS_PATH'])
    rescue Xmms::Client::ClientError
      puts 'Failed to connect to XMMS2 daemon.'
      puts 'Please make sure xmms2d is running and using the correct IPC path.'
      exit
    end
    super(@xc)
    @xc.add_to_glib_mainloop
    # TODO: handler for future deconection
  end
end
