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
    iter = @list.prepend
    iter[0]=id
    iter[1]=get(info, :title, "UNKNOW")
    iter[2]=get(info, :artist, "UNKNOW")
    iter[3]=get(info, :album, "UNKNOW")
    iter[4]=get(info, :rating, "UNKNOW").to_i
  end

  def erase_rating_with_id(id)
    @xc.medialib_entry_property_remove(id, :rating, "client/generic").notifier do
       false
    end
  end

  def erase_rating(iter)
    if iter
      erase_rating_with_id(iter[0])
      iter[4]=0
   else
      @xc.playback_current_id.notifier do |id|
        erase_rating_with_id(id)
        false
      end
      @list.iter_first[4]=0
    end
  end

  def rate_with_id(id,rate)
    @xc.medialib_entry_property_set(id, :rating, rate, "client/generic").notifier do
      false
    end
  end

  def rate(iter,rate)
    if iter
      rate_with_id(iter[0],rate)
      iter[4]=rate
    else
      @xc.playback_current_id.notifier do |id|
        rate_with_id(id,rate)
        false
      end
      @list.iter_first[4]=rate
    end
  end

end

class UserInteract

  def initialize()
    @xc = XmmsInteract.new()
    @window = Gtk::Window.new()

    view = initialize_tree()
    bbox = initialize_bbox()

    pack = Gtk::VBox.new()

    @window.add(pack)
    pack.pack_start(bbox,false,false,1)
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

    return scroll
  end

  def initialize_bbox
    bbox = Gtk::HButtonBox.new()

    button = Gtk::Button.new("No rating")
    button.signal_connect("clicked") do
      @xc.erase_rating(@view.selection.selected)
    end
    bbox.pack_start(button,false,true,1)

    for i in [1,2,3,4,5]
      button = initialize_rater_button(i)
      bbox.pack_start(button,false,true,1)
    end

    return bbox
  end

  def initialize_rater_button(i)
    button = Gtk::Button.new(i.to_s)
    button.signal_connect("clicked") do
      @xc.rate(@view.selection.selected,i)
    end
    return button
  end
end

user = UserInteract.new()

Gtk.main
