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

  def destroy!
    @runing = false
    @list = nil
  end

  def initialize(xc)
    @xc = xc

    @list = Gtk::ListStore.new(Integer,String, String, String, Integer, TrueClass, TrueClass, TrueClass, TrueClass, TrueClass)

    @runing = true

    @xc.broadcast_medialib_entry_changed.notifier do |id|
      if @runing
        @xc.medialib_get_info(id).notifier do |info|
          @list.each do |model,path,iter|
            if iter[0] == id
              iter[COL_ID]=id
              iter[COL_TITLE]=get(info, :title, "UNKNOW")
              iter[COL_ARTIST]=get(info, :artist, "UNKNOW")
              iter[COL_ALBUM]=get(info, :album, "UNKNOW")
              update_rating(iter,get(info, :rating, "UNKNOW").to_i)
            end
          end
          true
        end
      end
      @runing
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
    if rate == 0
      erase_rating(iter)
    else
      rate_with_id(iter[COL_ID],rate)
      update_rating(iter,rate)
    end
  end

end

class XmmsInteractPlayed < XmmsInteract
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

  def add_song_info(id, info)
    super(id, info)
    @last_reference ||= Gtk::TreeRowReference.new(@list, @list.iter_first.path)
  end


  def initialize(xc)
    super(xc)

    @num_song = 0
    @last_reference = nil

    @xc.playback_current_id.notifier do |id|
      add_song(id)
      @num_song += 1
      false
    end

    @xc.broadcast_playback_current_id.notifier do |id|
      add_song(id)
      @num_song += 1
      remove_last_song() if @num_song > MAX_SONG
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

  def self.equal(xc, field, value)
    coll = Xmms::Collection.universe.equal(field, value)

    return XmmsInteractCollection.new(xc, coll)
  end

  def self.parse(xc, pattern)
    coll = Xmms::Collection.parse(pattern)

    return XmmsInteractCollection.new(xc, coll)
  end
end

class UserInteract

  def initialize(xc, title, main=false)
    @xc = xc
    @window = Gtk::Window.new()
    @window.title = title

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

    if not main
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
      @xc.destroy!
      false
    end

    if main
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
    col = Gtk::TreeViewColumn.new(title,renderer, :text => colnum)
    col.expand = true
    col.resizable = true
    @view.append_column(col)
  end

  def current_iters
    selection = @view.selection
    if selection.selected_rows.length > 0
      return selection.selected_rows
    elsif @current_path
      return [@xc.list.get_iter(@current_path)]
    else
      return [@xc.list.iter_first]
    end
  end

  def current_iter
    path = current_iters[0]     # Using alway the first ???
    if path.is_a? Gtk::TreeIter
      iter=path
    else
      iter=@xc.list.get_iter(path)
    end
    return iter
  end

  def rating_menu(i)
    item = Gtk::MenuItem.new("Rate to _#{i}")
    item.signal_connect("activate") {
      current_iters.each do |iter|
        @xc.rate(iter,i)
      end
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

      item = Gtk::MenuItem.new("Rate _others")
      item.signal_connect("activate") {
        user_parse(@xc.xc)
      }
      menu.append(item)


      item = Gtk::MenuItem.new("_Erase rating")
      item.signal_connect("activate") {
        current_iters.each do |iter|
          @xc.erase_rating(iter)
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
    @view = Gtk::TreeView.new(@xc.list)
    @view.selection.mode=Gtk::SELECTION_MULTIPLE

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

    @xc.list.signal_connect('row-inserted') do |model, path, iter|
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
      iter = @xc.list.get_iter(path)
      if iter[XmmsInteract::COL_RATING] == i
        @xc.rate(iter, i-1)
      else
        @xc.rate(path,i)
      end
    end
    col.pack_start(renderer,false)
    col.add_attribute(renderer, :active, i+XmmsInteract::COL_RATING)
  end

  # TODO: reconnect would be better than quiting
  def watch_lost_conexion
    @xc.xc.on_disconnect do
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


def user_same(xc,field,value)
  UserInteract.new(XmmsInteractCollection.equal(xc,field,value),
                   "#{field}: #{value}")
end

def user_parse(xc)
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
        UserInteract.new(XmmsInteractCollection.parse(xc,entry.text),entry.text)
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
