#!/usr/bin/ruby

### Copyright (c) 2010, 2011, 2012 Rémi Vanicat
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
# REMI VANICAT BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
# IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# Except as contained in this notice, the name of Rémi Vanicat shall not be
# used in advertising or otherwise to promote the sale, use or other dealings
# in this Software without prior written authorization from Rémi Vanicat.

# This code is wrote using org-mode's babel's litterate programing
# you should modify xmms-gtk-rater.org, and not xmms-gtk-rater directly.

### About

# This is a small gtk client for xmms2 that will allow you to easily
# rate your song as you are playing them.
#
# Read the README.org for more information

### library requierement

require 'xmmsclient'
require 'xmmsclient_glib'
require 'glib2'
require 'gtk2'

### Utils
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


### Interacting with xmms
class XmmsInteract
  def get(info, attr, default=nil)
    info[attr].to_a[0][1]
  rescue NoMethodError => e
    default

  end

  def initialize
    @looking_for_medialib_list = []
    @current_song_watcher = []
    @views = []
    unless connect!
      puts 'Failed to connect to XMMS2 daemon.'
      puts 'Please make sure xmms2d is running and using the correct IPC path.'
      exit
    end
  end

  def connect!
    begin
      @xc = Xmms::Client.new('GtkRater').connect(ENV['XMMS_PATH'])
      @xc.on_disconnect do
        @views.each do |view|
          view.on_server_disconnect!
        end

        unless reconnect!
          GLib::Timeout.add_seconds(10) do
            not reconnect!
          end
        end
      end
    rescue Xmms::Client::ClientError
      return false
    end

    @xc.add_to_glib_mainloop

    looking_for_entry_change

    looking_at_current_song

    initialize_playlist

    return true
  end

  def reconnect!
    res = connect!
    if res
      @views.each do |view|
        view.on_server_reconnect!
      end
    end
    res
  end

  def register_connection_watcher(view)
    @views << view
  end

  def unregister_connection_watcher(view)
    @views.delete(view)
  end

  def looking_for_entry_change
    @xc.broadcast_medialib_entry_changed.notifier do |id|
      song_info(id) do |id, title, artist, album, rating|
        @looking_for_medialib_list.each do |list|
          list.song_changed(id, title, artist, album, rating)
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

  def looking_at_current_song
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

  def add_current_song_watcher(watcher)
    current_id do |id|
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

  def current_id(&body)
    @xc.playback_current_id.notifier do |id|
      yield(id)
    end
  end

  def song_info(id, &body)
    if id != 0
      @xc.medialib_get_info(id).notifier do |info|
        yield(id, get(info, :title), get(info, :artist), get(info, :album), get(info, :rating, "0").to_i)
        false
      end
    end
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

  def coll_query_info(coll,&body)
    @xc.coll_query_info(coll,['id', 'title', 'artist', 'album', 'rating']).notifier do |infos|
      body.call(infos)
      true
    end

  end

  def erase_rating(id)
    @xc.medialib_entry_property_remove(id, :rating, "client/generic").notifier do
      false
    end
  end

  def rate(id,rate)
    if rate == 0
      erase_rating(id)
    else
      @xc.medialib_entry_property_set(id, :rating, rate, "client/generic").notifier do
        false
      end
    end
  end

  PLAYLIST_REMOVE = 3
  PLAYLIST_CREATE = 0

  def initialize_playlist
    @playlist_list = nil
    @xc.playlist_list.notifier do |res|
      @playlist_list  = res.sort!
      true
    end

    @xc.broadcast_coll_changed.notifier do |res|
      if res[:namespace] == "Playlists"
        if res[:type] == PLAYLIST_REMOVE
          @playlist_list.delete(res[:name])
        elsif res[:type] == PLAYLIST_CREATE
          @playlist_list << res[:name]
          @playlist_list.sort!
        end
      end
      true
    end
  end

  def playlist_list
    @playlist_list
  end

  def add_to_playlist(id, pl)
    Xmms::Playlist.new(@xc, pl).add_entry(id)
  end
end


### Listing song
class SongList
  attr_reader :list
  attr_reader :xi

  COL_ID = 0
  COL_TITLE = 1
  COL_ARTIST = 2
  COL_ALBUM = 3
  COL_RATING = 4

  def initialize(xi)
    @xi = xi

    @list = Gtk::ListStore.new(Integer,String, String, String, Integer, TrueClass, TrueClass, TrueClass, TrueClass, TrueClass)

    @runing = true

    @xi.add_medialib_watcher(self)
  end

  def destroy!
    @runing = false
    @list = nil
    @xi.remove_medialib_watcher(self)
  end

  def set_song_infos(iter, id, title, artist, album, rating)
    iter.set_value(COL_ID,id)
    iter.set_value(COL_TITLE,title || "UNKNOW")
    iter[COL_ARTIST]=artist || "UNKNOW"
    iter[COL_ALBUM]=album || "UNKNOW"
    update_rating(iter, rating)
  end

  def update_rating(iter,rate)
    iter[COL_RATING]=rate
    for i in 1..5
      iter[COL_RATING+i] = rate >= i
    end
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

  def append_song_info(id, title, artist, album, rating)
    iter = @list.append
    set_song_infos(iter, id, title, artist, album, rating)
  end

  def register(view)
    @xi.register_connection_watcher(view)
  end

  def unregister(view)
    @xi.unregister_connection_watcher(view)
  end

  def with_id(path,&body)
    if path.is_a? Gtk::TreeIter
      iter=path
    else
      iter=@list.get_iter(path)
    end
    if iter
      body.call(iter[COL_ID])
    else
      @xi.current_id do |id|
        body.call(id)
        false
      end
    end
  end

  def rate(path,rate)
    with_id(path) do |id|
      @xi.rate(id, rate)
    end
  end

  def add_to_playlist(path, pl)
    with_id(path) do |id|
      @xi.add_to_playlist(id, pl)
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

  SORT_DEFAULT = [ COL_ID ]
  SORT_ARTIST = [ COL_ARTIST, COL_ALBUM, COL_TITLE, COL_ID ]
  SORT_ALBUM = [ COL_ALBUM, COL_TITLE, COL_ID ]
  SORT_TITLE = [ COL_TITLE, COL_ARTIST, COL_ALBUM, COL_ID ]

  def cmp_iter(iter1,iter2,cols)
    c = cols.collect do |col|
      if iter1[col] and iter2[col]
        iter1[col] <=> iter2[col]
      elsif iter1[col]
        -1
      elsif iter2[col]
        1
      elsif
        0
      end
    end

    c.reject { |i| i==0 }

    c[0] || 0
  end

  def initialize(xc,coll)
    super(xc)

    @coll = coll

    @list.set_sort_column_id(COL_ID)

    @list.set_default_sort_func do |iter1, iter2|
      cmp_iter(iter1,iter2,SORT_DEFAULT)
    end

    @list.set_sort_func(COL_ALBUM) do |iter1, iter2|
      cmp_iter(iter1,iter2,SORT_ALBUM)
    end

    @list.set_sort_func(COL_TITLE) do |iter1, iter2|
      cmp_iter(iter1,iter2,SORT_TITLE)
    end

    @list.set_sort_func(COL_ARTIST) do |iter1, iter2|
      cmp_iter(iter1,iter2,SORT_ARTIST)
    end
    load!
  end

  def reload!
    list.clear

    load!
  end

  def load!
    @xi.coll_each_song(@coll) do |id, title, artist, album, rating|
      append_song_info(id, title, artist, album, rating)
    end
  end

  def self.equal(xc, field, value)
    coll = Xmms::Collection.universe.equal(field, value)

    return self.new(xc, coll)
  end

  def self.parse(xc, pattern)
    coll = Xmms::Collection.parse(pattern)

    return self.new(xc, coll)
  end
end

class SongListDuplicate < SongListCollection

  SORT_DEFAULT = [ COL_TITLE ]
  SORT_ARTIST = [ COL_ARTIST, COL_TITLE, COL_ALBUM, COL_ID ]
  SORT_ALBUM = [ COL_ALBUM, COL_TITLE, COL_ID ]
  SORT_TITLE = [ COL_TITLE, COL_ARTIST, COL_ALBUM, COL_ID ]

  def field_value_cmp(a, b)
    if a
      if b
        a <=> b
      else
        1
      end
    else
      -1
    end
  end


  def song_compare(a, b)
    titlea = a.has_key?(:title) && a[:title]
    titleb = b.has_key?(:title) && b[:title]
    artista = a.has_key?(:artist) && a[:artist]
    artistb = b.has_key?(:artist) && b[:artist]
    if artista != artistb then
      field_value_cmp(artista, artistb)
    elsif titlea != titleb
      field_value_cmp(titlea, titleb)
    else
      a[:id] <=> b[:id]
    end
  end

  def str_prefix (a, b)
    if a.length > b.length
      false
    elsif a == b
      true
    elsif
      s = b[0,a.length]
      s == a
    end
  end

  def title_prefix (a,b)
    a and a[:artist] and a[:title] and a[:artist] == b[:artist] and
      str_prefix(a[:title], b[:title])
  end

  def append_song_hash(info)
    append_song_info(info[:id], info[:title], info[:artist], info[:album], info[:rating]?info[:rating]:0)
  end

  def initialize(xc,coll)
    super(xc,coll)
  end

  def load!
    @xi.coll_query_info(@coll) do |songs|
      if songs
        songs.sort! { |a,b| song_compare(a, b) }

        curinfo = nil
        added = false

        songs.each do |info|
          if title_prefix(curinfo, info)
            unless added
              append_song_hash(curinfo)
              added = true
            end
            append_song_hash(info)
          else
            added = false
            curinfo = info
          end
        end
      end
    end
  end
end


### displaying listing
class UserInteract
  def main?
    @main
  end

  def on_server_reconnect!
    @window.sensitive=true
  end

  def on_server_disconnect!
    @window.sensitive=false
  end

  def initialize(slist, title, main=false)
    @slist = slist
    @window = Gtk::Window.new()
    @window.title = title
    @window.icon=Gdk::Pixbuf.new("/usr/share/pixmaps/xmms2-48.png")
    @main = main

    @slist.register(self)

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
      @slist.unregister(self)
      @slist.destroy!
      false
    end

    if main?
      @window.signal_connect('destroy') do
        Gtk.main_quit
      end
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

      unless main?
        item = Gtk::MenuItem.new("_Reload")
        item.signal_connect("activate") {
          @slist.reload!
        }
        menu.append(item)
      end


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

      item = Gtk::MenuItem.new("Looking for _duplicate")
      item.signal_connect("activate") {
        duplicate_parse(@slist.xi)
      }
      menu.append(item)


      item = Gtk::MenuItem.new("_Erase rating")
      item.signal_connect("activate") {
        current_iters.each do |iter|
          @slist.rate(iter,0)
        end
      }
      menu.append(item)

      for i in 1..5
        item=rating_menu(i)
        menu.append(item)
      end

      item = Gtk::MenuItem.new("Add to _playlist")
      menu.signal_connect("show") do
        item.submenu = playlist_menu do |pl|
          current_iters.each do |iter|
            @slist.add_to_playlist(iter, pl)
          end
        end
      end
      menu.append(item)

      menu.show_all
      @action_menu = menu
    end
    return @action_menu
  end

  def playlist_menu(&body)
    playlists = @slist.xi.playlist_list
    if playlists
      menu = Gtk::Menu.new
      playlists.each do |playlist|
        unless playlist =~ /^_/
          item = Gtk::MenuItem.new(playlist, use_underline = false)
          item.signal_connect("activate") do
            body.call(playlist)
          end
          menu.append(item)
        end
      end
      menu.show_all
      menu
    else
      nil
    end
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
end


### some builder
def user_same(xi,field,value)
  UserInteract.new(SongListCollection.equal(xi,field,value),
                   "#{field}: #{value}")
end

def duplicate_same(xi,field,value)
  UserInteract.new(SongListDuplicate.equal(xi,field,value),
                   "Duplicate #{field}: #{value}")
end

def create_from_col(title, &body)
  dialog=Gtk::Dialog.new(title,
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
        body.call(entry.text)
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

def user_parse(xi)
  create_from_col("Rate from search") do |pattern|
    UserInteract.new(SongListCollection.parse(xi,pattern),pattern)
  end
end

def duplicate_parse(xi)
  create_from_col("Look for duplicate") do |pattern|
    UserInteract.new(SongListDuplicate.parse(xi,pattern),pattern)
  end
end


### The main stuff

user = UserInteract.new(SongListPlayed.new(XmmsInteract.new),"Xmms Rater", true)

$0 = "xmms-gtk-rater"

Gtk.main
