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

    @list = Gtk::ListStore.new(Integer,String, String, String, Integer, TrueClass, TrueClass, TrueClass, TrueClass, TrueClass)

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
    iter = @list.prepend
    iter[0]=id
    iter[1]=get(info, :title, "UNKNOW")
    iter[2]=get(info, :artist, "UNKNOW")
    iter[3]=get(info, :album, "UNKNOW")
    update_rating(iter,get(info, :rating, "UNKNOW").to_i)
  end

  def update_rating(iter,rate)
    iter[4]=rate
    for i in [0,1,2,3,4]
      iter[5+i] = rate > i
    end
  end

  def erase_rating_with_id(id)
    @xc.medialib_entry_property_remove(id, :rating, "client/generic").notifier do
       false
    end
  end

  def erase_rating(iter)
    if iter
      erase_rating_with_id(iter[0])
      update_rating(iter,0)
   else
      @xc.playback_current_id.notifier do |id|
        erase_rating_with_id(id)
        false
      end
      update_rating(@list.iter_first,0)
    end
  end

  def rate_with_id(id,rate)
    @xc.medialib_entry_property_set(id, :rating, rate, "client/generic").notifier do
      false
    end
  end

  def rate(path,rate)
    iter=@list.get_iter(path)
    if iter[4] == rate
      rate = rate - 1
    end
    if rate == 0
      erase_rating(iter)
    else
      rate_with_id(iter[0],rate)
      update_rating(iter,rate)
    end
  end

end

class UserInteract

  def initialize()
    @xc = XmmsInteract.new()
    @window = Gtk::Window.new()

    view = initialize_tree()

    pack = Gtk::VBox.new()

    @window.add(pack)
    pack.pack_start(view,true,true,1)


    @window.signal_connect('delete_event') do
      false
    end

    @window.signal_connect('destroy') do
      Gtk.main_quit
    end

    @window.show_all
  end

  def initialize_tree
    @view = Gtk::TreeView.new(@xc.list)
    scroll = Gtk::ScrolledWindow.new()
    scroll.add(@view)
    scroll.set_policy(Gtk::POLICY_AUTOMATIC, Gtk::POLICY_AUTOMATIC)

    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("id",renderer, :text => 0)
    @view.append_column(col)
    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("Title",renderer, :text => 1)
    col.expand = true
    @view.append_column(col)
    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("Artist",renderer, :text => 2)
    col.expand = true
    @view.append_column(col)
    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("Album",renderer, :text => 3)
    col.expand = true
    @view.append_column(col)
    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("Rating",renderer, :text => 4)
    @view.append_column(col)

    for i in 1..5
      col=initialize_rater_toggle(i)
      @view.append_column(col)
    end

    return scroll
  end

  def initialize_rater_toggle(i)
    renderer = Gtk::CellRendererToggle.new
    renderer.activatable = true
    renderer.signal_connect('toggled') do |w,path|
      @xc.rate(path,i)
    end
    col = Gtk::TreeViewColumn.new(i.to_s,renderer, :active => i+4)
    col.expand=false
    return col
  end
end

user = UserInteract.new()

Gtk.main
