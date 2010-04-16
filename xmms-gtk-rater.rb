#!/usr/bin/env ruby

require 'xmmsclient'
require 'xmmsclient_glib'
require 'glib2'
require 'gtk2'

module Xmms
  class Collection
    # :call-seq:
    #  Collection.equal(field,value,from=Collection.universe) -> collection
    #
    # Returns a new collection for song whose field is value in from
    def equal(field, value)
      coll = Xmms::Collection.new(TYPE_EQUALS)
      coll.attributes["field"]=field
      coll.attributes["value"]=value
      coll.operands<< self
      return coll
    end
  end
end

def debug(*arg)
  puts(*arg)
end

class XmmsInteract
  attr_reader :list
  attr_reader :xc

  COL_ID = 0
  COL_TITLE = 1
  COL_ARTIST = 2
  COL_ALBUM = 3
  COL_RATING = 4

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
    iter[COL_ID]=id
    iter[COL_TITLE]=get(info, :title, "UNKNOW")
    iter[COL_ARTIST]=get(info, :artist, "UNKNOW")
    iter[COL_ALBUM]=get(info, :album, "UNKNOW")
    update_rating(iter,get(info, :rating, "UNKNOW").to_i)
  end

  def update_rating(iter,rate)
    iter[COL_RATING]=rate
    for i in 1..5
      iter[COL_RATING+i] = rate >= i
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
    if path.is_a? Gtk::TreeIter
      iter=path
    else
      iter=@list.get_iter(path)
    end
    if iter[COL_RATING] == rate
      rate = rate - 1
    end
    if rate == 0
      erase_rating(iter)
    else
      rate_with_id(iter[COL_ID],rate)
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
  coll = Xmms::Collection.universe.equal(field, value)

  return XmmsInteractCollection.new(xc, coll)
end

class UserInteract

  def initialize(xc, title, main=false)
    @xc = xc
    @window = Gtk::Window.new()
    @window.title = title

    view = initialize_tree()

    pack = Gtk::VBox.new()
    menubar = Gtk::MenuBar.new

    file = Gtk::MenuItem.new("File")
    file.submenu=Gtk::Menu.new

    action = Gtk::MenuItem.new("Action")
    action.submenu = action_menu

    if not main
      close = Gtk::ImageMenuItem.new(Gtk::Stock::CLOSE)
      close.signal_connect('activate') do
        @window.destroy
        false
      end
      file.submenu.append(close)
    end

    quit = Gtk::ImageMenuItem.new(Gtk::Stock::QUIT)

    quit.signal_connect('activate') do
      Gtk.main_quit
      false
    end

    file.submenu.append(quit)

    menubar.append(file)
    menubar.append(action)

    @window.add(pack)
    pack.pack_start(menubar,false,false,1)
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

  def initialize_std_col(title, colnum)
    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new(title,renderer, :text => colnum)
    col.expand = true
    col.resizable = true
    @view.append_column(col)
  end

  def current_iter
    return @xc.list.get_iter(@current_path) if @current_path
    selection = @view.selection
    if selection.selected
      return selection.selected
    else
      return @xc.list.iter_first
    end
  end

  def rating_menu(i)
    item = Gtk::MenuItem.new("Rate to _#{i}")
    item.signal_connect("activate") {
      @xc.rate(current_iter,i)
    }
    return item
  end

  def action_menu
    unless @action_menu
      menu = Gtk::Menu.new
      item = Gtk::MenuItem.new("Show same _artist")
      item.signal_connect("activate") {
        user_same(@xc.xc, "artist", current_iter[XmmsInteract::COL_ARTIST])
      }
      menu.append(item)

      item = Gtk::MenuItem.new("Show same al_bum")
      item.signal_connect("activate") {
        user_same(@xc.xc, "album", current_iter[XmmsInteract::COL_ALBUM])
      }
      menu.append(item)

      item = Gtk::MenuItem.new("Show same _title")
      item.signal_connect("activate") {
        user_same(@xc.xc, "title", current_iter[XmmsInteract::COL_TITLE])
      }
      menu.append(item)

      for i in 1..5
        item=rating_menu(i)
        menu.append(item)
      end


      menu.show_all
      @action_menu = menu
    end
    return @action_menu
  end

  def initialize_tree
    @view = Gtk::TreeView.new(@xc.list)
    scroll = Gtk::ScrolledWindow.new()
    scroll.add(@view)
    scroll.set_policy(Gtk::POLICY_NEVER, Gtk::POLICY_AUTOMATIC)

    renderer = Gtk::CellRendererText.new
    col = Gtk::TreeViewColumn.new("id",renderer, :text => XmmsInteract::COL_ID)
    @view.append_column(col)
    renderer = Gtk::CellRendererText.new

    initialize_std_col("Title", XmmsInteract::COL_TITLE)

    initialize_std_col("Artist", XmmsInteract::COL_ARTIST)

    initialize_std_col("Album", XmmsInteract::COL_ALBUM)

    col = Gtk::TreeViewColumn.new("rating")
    for i in 1..5
      initialize_rater_toggle(col,i)
    end
    col.expand=false
    @view.append_column(col)

    @view.search_column=XmmsInteract::COL_TITLE

    @view.signal_connect("button_press_event") do |widget, event|
      if event.kind_of? Gdk::EventButton and event.button == 3
        @current_path = @view.get_path(event.x, event.y)
        @current_path = @view.get_path(event.x, event.y)[0] if @current_path
        action_menu.popup(nil, nil, event.button, event.time)
      end
    end

    @view.signal_connect("popup_menu") {
      @current_path = nil
      action_menu.popup(nil, nil, 0, Gdk::Event::CURRENT_TIME)
    }

    return scroll
  end

  def initialize_rater_toggle(col,i)
    renderer = Gtk::CellRendererToggle.new
    renderer.activatable = true
    renderer.signal_connect('toggled') do |w,path|
      @xc.rate(path,i)
    end
    col.pack_start(renderer,false)
    col.add_attribute(renderer, :active, i+XmmsInteract::COL_RATING)
  end
end


def user_same(xc,field,value)
  UserInteract.new(xmms_same(xc,field,value),"#{field}: #{value}")
end

begin
  xc = Xmms::Client.new('Rater').connect(ENV['XMMS_PATH'])
rescue Xmms::Client::ClientError
  puts 'Failed to connect to XMMS2 daemon.'
  puts 'Please make sure xmms2d is running and using the correct IPC path.'
  exit
end

xc.add_to_glib_mainloop

user = UserInteract.new(XmmsInteractPlayed.new(xc),"Xmms Rater", true)

Gtk.main
