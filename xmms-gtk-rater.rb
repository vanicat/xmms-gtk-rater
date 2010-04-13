#!/usr/bin/env ruby

require 'xmmsclient'
require 'xmmsclient_glib'
require 'glib2'
require 'gtk2'
require 'delegate'

def debug(*arg)
  puts(*arg)
end

class XmmsInteract < DelegateClass(Xmms::Client)
  attr_reader :list

  def get(info, attr, default=nil)
    info[attr].map[0][1]
  rescue NoMethodError => e
    default
  end

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

    @list = Gtk::ListStore.new(Integer,String, String, String, Integer)

    @xc.playback_current_id.notifier do |id|
      add_song(id)
      false
    end

    @xc.broadcast_playback_current_id.notifier do |id|
      add_song(id)
      true
    end
  end

  def add_song(id)
    if id != 0
      @xc.medialib_get_info(id).notifier do |res|
        add_song_info(id,res)
        false
      end
    end
  end

  def add_song_info(id, info)
    iter = @list.append
    iter[0]=id
    iter[1]=get(info, :title, "UNKNOW")
    iter[2]=get(info, :artist, "UNKNOW")
    iter[3]=get(info, :album, "UNKNOW")
    iter[4]=get(info, :rating, "UNKNOW").to_i
  end

end

class UserInteract

  def initialize()
    @xc = XmmsInteract.new()
    @window = Gtk::Window.new()
    @view = Gtk::TreeView.new(@xc.list)
    scroll = Gtk::ScrolledWindow.new()
    @window.add(scroll)
    scroll.add(@view)
    scroll.set_policy(Gtk::POLICY_AUTOMATIC, Gtk::POLICY_AUTOMATIC)

    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("id",renderer, :text => 0)
    @view.append_column(col)
    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("Title",renderer, :text => 1)
    @view.append_column(col)
    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("Album",renderer, :text => 2)
    @view.append_column(col)
    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("Artist",renderer, :text => 3)
    @view.append_column(col)
    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("Rating",renderer, :text => 4)
    @view.append_column(col)

    @window.signal_connect('delete_event') do
      false
    end

    @window.signal_connect('destroy') do
      Gtk.main_quit
    end

    @window.show_all
  end
end

user = UserInteract.new()

Gtk.main
