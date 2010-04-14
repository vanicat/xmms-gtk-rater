#!/usr/bin/env ruby

require 'xmmsclient'
require 'xmmsclient_glib'
require 'glib2'
require 'gtk2'

def debug(*arg)
  puts(*arg)
end

class XmmsInteract
  attr_reader :list
  attr_reader :xc

  def get(info, attr, default=nil)
    info[attr].map[0][1]
  rescue NoMethodError => e
    default
  end

  def initialize(xc)
    @xc = xc

    @list = Gtk::ListStore.new(Integer,String, String, String, Integer, TrueClass, TrueClass, TrueClass, TrueClass, TrueClass)

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

class XmmsInteractPlayed < XmmsInteract
  def initialize(xc)
    super(xc)

    @xc.playback_current_id.notifier do |id|
      add_song(id)
      false
    end

    @xc.broadcast_playback_current_id.notifier do |id|
      add_song(id)
      true
    end
  end

end

class XmmsInteractCollection < XmmsInteract

  def initialize(xc,coll)
    super(xc)

    @xc.coll_query_ids(coll).notifier do |res|
      res.each do |id|
        add_song(id)
      end
      true
    end
  end
end

def xmms_same(xc, field, value)
  coll = Xmms::Collection.new(Xmms::Collection::TYPE_EQUALS)
  coll.attributes["field"]=field
  coll.attributes["value"]=value
  coll.operands<< Xmms::Collection.universe

  return XmmsInteractCollection.new(xc, coll)
end

class UserInteract

  def initialize(xc, main=false)
    @xc = xc
    @window = Gtk::Window.new()

    view = initialize_tree()

    pack = Gtk::VBox.new()

    @window.add(pack)
    pack.pack_start(view,true,true,1)


    @window.signal_connect('delete_event') do
      false
    end

    if main
      @window.signal_connect('destroy') do
        Gtk.main_quit
      end
    end

    @window.show_all
  end

  def initialize_std_col(view, title, colnum)
    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new(title,renderer, :text => colnum)
    col.expand = true
    col.resizable = true
    view.append_column(col)
  end

  def initialize_tree
    view = Gtk::TreeView.new(@xc.list)
    scroll = Gtk::ScrolledWindow.new()
    scroll.add(view)
    scroll.set_policy(Gtk::POLICY_NEVER, Gtk::POLICY_AUTOMATIC)

    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("id",renderer, :text => 0)
    view.append_column(col)
    renderer = Gtk::CellRendererText.new

    initialize_std_col(view, "Title", 1)

    initialize_std_col(view, "Artist", 2)

    initialize_std_col(view, "Album", 3)

    col = Gtk::TreeViewColumn.new("rating")
    for i in 1..5
      initialize_rater_toggle(col,i)
    end
    col.expand=false
    view.append_column(col)

    view.search_column=1

    return scroll
  end

  def initialize_rater_toggle(col,i)
    renderer = Gtk::CellRendererToggle.new
    renderer.activatable = true
    renderer.signal_connect('toggled') do |w,path|
      @xc.rate(path,i)
    end
    col.pack_start(renderer,false)
    col.add_attribute(renderer, :active, i+4)
  end
end


def user_same(xc,field,value)
  UserInteract.new(xmms_same(xc,field,value))
end

begin
  xc = Xmms::Client.new('Rater').connect(ENV['XMMS_PATH'])
rescue Xmms::Client::ClientError
  puts 'Failed to connect to XMMS2 daemon.'
  puts 'Please make sure xmms2d is running and using the correct IPC path.'
  exit
end

xc.add_to_glib_mainloop

user = UserInteract.new(XmmsInteractPlayed.new(xc),true)

Gtk.main
