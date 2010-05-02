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
  attr_reader :xc

  def get(info, attr, default=nil)
    info[attr].map[0][1]
  rescue NoMethodError => e
    default
  end

  def initialize
    begin
      @xc = Xmms::Client.new('GtkRater').connect(ENV['XMMS_PATH'])
    rescue Xmms::Client::ClientError
      puts 'Failed to connect to XMMS2 daemon.'
      puts 'Please make sure xmms2d is running and using the correct IPC path.'
      exit
    end

    @xc.add_to_glib_mainloop

    @looking_for_medialib_list = []
    @current_song_watcher = []

    @xc.broadcast_medialib_entry_changed.notifier do |id|
      song_info(id) do |id, title, artist, album, rating|
        @looking_for_medialib_list.each do |list|
          list.song_changed(id, title, artist, album, rating)
        end
        true
      end
      true
    end

    @xc.broadcast_playback_current_id.notifier do |id|
      song_info(id) do |id, title, artist, album, rating|
        @current_song_watcher.each do |watcher|
          watcher.current_song_info(id, title, artist, album, rating)
        end
        true
      end
      true
    end
  end

  def add_medialib_watcher(watcher)
    @looking_for_medialib_list << watcher
  end

  def remove_medialib_watcher(watcher)
    @looking_for_medialib_list.delete(watcher)
  end

  def song_info(id, &body)
    if id != 0
      @xc.medialib_get_info(id).notifier do |info|
        yield(id, get(info, :title), get(info, :artist), get(info, :album), get(info, :rating, "0").to_i)
        false
      end
    end
  end

  def add_current_song_watcher(watcher)
    @xc.playback_current_id.notifier do |id|
      song_info(id) do |id, title, artist, album, rating|
        watcher.current_song_info(id, title, artist, album, rating)
      end
      false
    end
    @current_song_watcher << watcher
  end

  def remove_current_song_watcher(watcher)
    @current_song_watcher.delete(watcher)
  end

  def coll_each_song(coll, &body)
    @xc.coll_query_ids(coll).notifier do |res|
      if res
        res.each do |id|
          song_info(id, &body)
        end
      end
      true
    end
  end

end

class SongList
  attr_reader :list
  attr_reader :xi

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

  def destroy!
    @runing = false
    @list = nil
    @xi.remove_medialib_watcher(self)
  end

  def initialize(xi)
    @xi = xi

    @list = Gtk::ListStore.new(Integer,String, String, String, Integer, TrueClass, TrueClass, TrueClass, TrueClass, TrueClass)

    @runing = true

    @xi.add_medialib_watcher(self)
  end

  def set_song_infos(iter, id, title, artist, album, rating)
    iter[COL_ID]=id
    iter[COL_TITLE]=title || "UNKNOW"
    iter[COL_ARTIST]=artist || "UNKNOW"
    iter[COL_ALBUM]=album || "UNKNOW"
    update_rating(iter, rating)
  end

  def song_changed(id, title, artist, album, rating)
    @list.each do |model,path,iter|
      set_song_infos(iter, id, title, artist, album, rating) if iter[0] == id
    end
  end

  def add_song_info(id, title, artist, album, rating)
    iter = @list.prepend
    set_song_infos(iter, id, title, artist, album, rating)
  end

  def update_rating(iter,rate)
    iter[COL_RATING]=rate
    for i in 1..5
      iter[COL_RATING+i] = rate >= i
    end
  end

  def erase_rating_with_id(id)
    @xi.xc.medialib_entry_property_remove(id, :rating, "client/generic").notifier do
       false
    end
  end

  def erase_rating(path)
    if path.is_a? Gtk::TreeIter
      iter=path
    else
      iter=@list.get_iter(path)
    end
    if iter
      erase_rating_with_id(iter[0])
      update_rating(iter,0)
   else
      @xi.xc.playback_current_id.notifier do |id|
        erase_rating_with_id(id)
        false
      end
      update_rating(@list.iter_first,0)
    end
  end

  def rate_with_id(id,rate)
    @xi.xc.medialib_entry_property_set(id, :rating, rate, "client/generic").notifier do
      false
    end
  end

  def rate(path,rate)
    if path.is_a? Gtk::TreeIter
      iter=path
    else
      iter=@list.get_iter(path)
    end
    if rate == 0
      erase_rating(iter)
    else
      rate_with_id(iter[COL_ID],rate)
      update_rating(iter,rate)
    end
  end

end

class SongListPlayed < SongList
  MAX_SONG = 50

  def remove_last_song()
    cur = @list.get_iter(@last_reference.path)
    previous = @last_reference.path
    previous.prev!
    @list.remove(cur)
    @last_reference = Gtk::TreeRowReference.new(@list, previous)
    @num_song -= 1
    remove_last_song() if @num_song > MAX_SONG
  end

  def add_song_info(id, title, artist, album, rating)
    super(id, title, artist, album, rating)
    @num_song += 1
    @last_reference ||= Gtk::TreeRowReference.new(@list, @list.iter_first.path)
  end


  def current_song_info(id, title, artist, album, rating)
    add_song_info(id, title, artist, album, rating)
    remove_last_song() if @num_song > MAX_SONG
  end

  def initialize(xc)
    super(xc)

    @num_song = 0
    @last_reference = nil

    @xi.add_current_song_watcher(self)
  end

end

class SongListCollection < SongList

  def initialize(xc,coll)
    super(xc)

    @list.set_sort_column_id(COL_ID)

    @list.set_default_sort_func do |iter1, iter2|
      iter1[COL_ID] <=> iter2[COL_ID]
    end

    @list.set_sort_func(COL_ALBUM) do |iter1, iter2|
      [iter1[COL_ALBUM], iter1[COL_TITLE], iter1[COL_ID]] <=> [iter2[COL_ALBUM], iter2[COL_TITLE], iter2[COL_ID]]
    end

    @list.set_sort_func(COL_TITLE) do |iter1, iter2|
      [iter1[COL_TITLE], iter1[COL_ARTIST], iter1[COL_ALBUM], iter1[COL_ID]] <=> [iter2[COL_TITLE], iter2[COL_ARTIST], iter2[COL_ALBUM], iter2[COL_ID]]
    end

    @list.set_sort_func(COL_ARTIST) do |iter1, iter2|
      [iter1[COL_ARTIST], iter1[COL_ALBUM], iter1[COL_TITLE], iter1[COL_ID]] <=> [iter2[COL_ARTIST], iter2[COL_ALBUM], iter2[COL_TITLE], iter2[COL_ID]]
    end


    @xi.coll_each_song(coll) do |id, title, artist, album, rating|
      add_song_info(id, title, artist, album, rating)
    end
  end

  def self.equal(xc, field, value)
    coll = Xmms::Collection.universe.equal(field, value)

    return SongListCollection.new(xc, coll)
  end

  def self.parse(xc, pattern)
    coll = Xmms::Collection.parse(pattern)

    return SongListCollection.new(xc, coll)
  end
end

class UserInteract

  def main?
    @main
  end

  def initialize(slist, title, main=false)
    @slist = slist
    @window = Gtk::Window.new()
    @window.title = title
    @main = main

    view = initialize_tree()

    pack = Gtk::VBox.new()
    menubar = Gtk::MenuBar.new

    ag = Gtk::AccelGroup.new

    file = Gtk::MenuItem.new("_File")
    file.submenu=Gtk::Menu.new
    file.submenu.accel_group=ag

    action = Gtk::MenuItem.new("_Action")
    action.submenu = action_menu
    action.submenu.accel_group=ag

    if not main?
      close = Gtk::ImageMenuItem.new(Gtk::Stock::CLOSE,ag)
      close.signal_connect('activate') do
        @window.destroy
        false
      end
      file.submenu.append(close)
    end

    quit = Gtk::ImageMenuItem.new(Gtk::Stock::QUIT,ag)

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

    @window.signal_connect('destroy') do
      @slist.destroy!
      false
    end

    if main?
      @window.signal_connect('destroy') do
        Gtk.main_quit
      end

      watch_lost_conexion
    end

    @window.add_accel_group(ag)
    @window.show_all
  end

  def initialize_std_col(title, colnum)
    renderer = Gtk::CellRendererText.new
    renderer.ellipsize = Pango::ELLIPSIZE_END
    col = Gtk::TreeViewColumn.new(title,renderer, :text => colnum)
    col.expand = true
    col.resizable = true
    col.sizing = Gtk::TreeViewColumn::FIXED
    col.fixed_width = 120
    col.sort_column_id = colnum unless main?
    @view.append_column(col)
  end

  def current_iters
    selection = @view.selection
    if selection.selected_rows.length > 0
      return selection.selected_rows
    elsif @current_path
      return [@slist.list.get_iter(@current_path)]
    else
      return [@slist.list.iter_first]
    end
  end

  def current_iter
    path = current_iters[0]     # Using alway the first ???
    if path.is_a? Gtk::TreeIter
      iter=path
    else
      iter=@slist.list.get_iter(path)
    end
    return iter
  end

  def rating_menu(i)
    item = Gtk::MenuItem.new("Rate to _#{i}")
    item.signal_connect("activate") {
      current_iters.each do |iter|
        @slist.rate(iter,i)
      end
    }
    return item
  end

  def action_menu
    unless @action_menu
      menu = Gtk::Menu.new
      item = Gtk::MenuItem.new("Show same _artist")
      item.signal_connect("activate") {
        user_same(@slist.xi, "artist", current_iter[SongList::COL_ARTIST])
      }
      menu.append(item)

      item = Gtk::MenuItem.new("Show same al_bum")
      item.signal_connect("activate") {
        user_same(@slist.xi, "album", current_iter[SongList::COL_ALBUM])
      }
      menu.append(item)

      item = Gtk::MenuItem.new("Show same _title")
      item.signal_connect("activate") {
        user_same(@slist.xi, "title", current_iter[SongList::COL_TITLE])
      }
      menu.append(item)

      item = Gtk::MenuItem.new("Rate _others")
      item.signal_connect("activate") {
        user_parse(@slist.xi)
      }
      menu.append(item)


      item = Gtk::MenuItem.new("_Erase rating")
      item.signal_connect("activate") {
        current_iters.each do |iter|
          @slist.erase_rating(iter)
        end
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
    @view = Gtk::TreeView.new(@slist.list)
    @view.selection.mode=Gtk::SELECTION_MULTIPLE

    scroll = Gtk::ScrolledWindow.new()
    scroll.add(@view)
    scroll.set_policy(Gtk::POLICY_NEVER, Gtk::POLICY_AUTOMATIC)

    initialize_std_col("Title", SongList::COL_TITLE)

    initialize_std_col("Artist", SongList::COL_ARTIST)

    initialize_std_col("Album", SongList::COL_ALBUM)

    col = Gtk::TreeViewColumn.new("rating")
    for i in 1..5
      initialize_rater_toggle(col,i)
    end
    col.expand=false
    @view.append_column(col)

    @view.search_column=SongList::COL_TITLE

    @view.signal_connect("button_press_event") do |widget, event|
      if event.kind_of? Gdk::EventButton and event.button == 3
        path = @view.get_path(event.x, event.y)
        @current_path = path[0] if path
        action_menu.popup(nil, nil, event.button, event.time)
      end
    end

    @view.signal_connect("popup_menu") {
      @current_path = nil
      action_menu.popup(nil, nil, 0, Gdk::Event::CURRENT_TIME)
    }

    @slist.list.signal_connect('row-inserted') do |model, path, iter|
      pos = scroll.vscrollbar.adjustment.value
      if pos == 0
        handler = scroll.vscrollbar.adjustment.signal_connect('changed') do
          scroll.vscrollbar.adjustment.signal_handler_disconnect(handler)
          GLib::Idle.add do
            scroll.vscrollbar.adjustment.value = 0
            false
          end
        end
      end
      true
    end

    return scroll
  end

  def initialize_rater_toggle(col,i)
    renderer = Gtk::CellRendererToggle.new
    renderer.activatable = true
    renderer.signal_connect('toggled') do |w,path|
      iter = @slist.list.get_iter(path)
      if iter[SongList::COL_RATING] == i
        @slist.rate(iter, i-1)
      else
        @slist.rate(path,i)
      end
    end
    col.pack_start(renderer,false)
    col.add_attribute(renderer, :active, i+SongList::COL_RATING)
  end

  # TODO: reconnect would be better than quiting
  def watch_lost_conexion
    @slist.xi.xc.on_disconnect do
      dialog = Gtk::Dialog.new("Connection lost",
                               @window,
                               Gtk::Dialog::DESTROY_WITH_PARENT,
                               [ Gtk::Stock::OK, Gtk::Dialog::RESPONSE_NONE ])

      # Ensure that the dialog box is destroyed when the user responds.
      dialog.signal_connect('response') { Gtk.main_quit }

      # Add the message in a label, and show everything we've added to the dialog.
      dialog.vbox.add(Gtk::Label.new("Connection to xmms lost, quiting"))
      dialog.show_all
    end
  end
end


def user_same(xi,field,value)
  UserInteract.new(SongListCollection.equal(xi,field,value),
                   "#{field}: #{value}")
end

def user_parse(xi)
  dialog=Gtk::Dialog.new("Rate from search",
                         nil,
                         Gtk::Dialog::DESTROY_WITH_PARENT,
                         [Gtk::Stock::OK, Gtk::Dialog::RESPONSE_ACCEPT],
                         [Gtk::Stock::CANCEL, Gtk::Dialog::RESPONSE_REJECT])
  dialog.vbox.add(Gtk::Label.new("collection pattern:"))
  entry=Gtk::Entry.new()
  dialog.vbox.add(entry)

  entry.signal_connect('activate') do |v|
    dialog.response(Gtk::Dialog::RESPONSE_ACCEPT)
  end

  dialog.show_all
  dialog.run do |response|
    if response == Gtk::Dialog::RESPONSE_ACCEPT
      begin
        UserInteract.new(SongListCollection.parse(xi,entry.text),entry.text)
      rescue Exception => e
        message = Gtk::MessageDialog.new(nil,
                                        Gtk::Dialog::DESTROY_WITH_PARENT,
                                        Gtk::MessageDialog::WARNING,
                                        Gtk::MessageDialog::BUTTONS_CLOSE,
                                        "Invalid pattern '%s'" % entry.text)
        message.run
        message.destroy
      end
    end
    dialog.destroy
  end
end

user = UserInteract.new(SongListPlayed.new(XmmsInteract.new),"Xmms Rater", true)

Gtk.main
