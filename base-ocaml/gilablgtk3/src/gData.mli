(**************************************************************************)
(*                Lablgtk                                                 *)
(*                                                                        *)
(*    This program is free software; you can redistribute it              *)
(*    and/or modify it under the terms of the GNU Library General         *)
(*    Public License as published by the Free Software Foundation         *)
(*    version 2, with the exception described in file COPYING which       *)
(*    comes with the library.                                             *)
(*                                                                        *)
(*    This program is distributed in the hope that it will be useful,     *)
(*    but WITHOUT ANY WARRANTY; without even the implied warranty of      *)
(*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the       *)
(*    GNU Library General Public License for more details.                *)
(*                                                                        *)
(*    You should have received a copy of the GNU Library General          *)
(*    Public License along with this program; if not, write to the        *)
(*    Free Software Foundation, Inc., 59 Temple Place, Suite 330,         *)
(*    Boston, MA 02111-1307  USA                                          *)
(*                                                                        *)
(*                                                                        *)
(**************************************************************************)

(* $Id$ *)

open Gtk

(** Non-Widgets objects carrying data *)

(** {3 GtkAdjustement} *)

(** @gtkdoc gtk GtkAdjustment *)
class adjustment_signals : [> adjustment] Gobject.obj ->
  object
    inherit GObj.gtkobj_signals
    method changed : callback:(unit -> unit) -> GtkSignal.id
    method value_changed : callback:(unit -> unit) -> GtkSignal.id
    method notify_lower : callback:(float -> unit) -> GtkSignal.id
    method notify_page_increment : callback:(float -> unit) -> GtkSignal.id
    method notify_page_size : callback:(float -> unit) -> GtkSignal.id
    method notify_step_increment : callback:(float -> unit) -> GtkSignal.id
    method notify_upper : callback:(float -> unit) -> GtkSignal.id
    method notify_value : callback:(float -> unit) -> GtkSignal.id
  end

(** A GtkObject representing an adjustable bounded value
   @gtkdoc gtk GtkAdjustment *)
class adjustment : Gtk.adjustment Gobject.obj ->
  object
    inherit GObj.gtkobj
    method as_adjustment : Gtk.adjustment Gobject.obj
    method clamp_page : lower:float -> upper:float -> unit
    method connect : adjustment_signals
    method set_value : float -> unit
    method lower : float
    method upper : float
    method value : float
    method step_increment : float
    method page_increment : float
    method page_size : float
    method set_bounds :
      ?lower:float -> ?upper:float -> ?step_incr:float ->
      ?page_incr:float -> ?page_size:float -> unit -> unit
    method set_lower : float -> unit
    method set_page_increment : float -> unit
    method set_page_size : float -> unit
    method set_step_increment : float -> unit
    method set_upper : float -> unit
    method set_value : float -> unit
  end

(** @gtkdoc gtk GtkAdjustment 
    @param lower default value is [0.]
    @param upper default value is [100.]
    @param step_incr default value is [1.]
    @param page_incr default value is [10.]
    @param page_size default value is [10.] *)
val adjustment :
  ?value:float ->
  ?lower:float ->
  ?upper:float ->
  ?step_incr:float ->
  ?page_incr:float -> ?page_size:float -> unit -> adjustment

val as_adjustment : adjustment -> Gtk.adjustment Gobject.obj
val conv_adjustment : adjustment Gobject.data_conv
val conv_adjustment_option : adjustment option Gobject.data_conv

(** {3 Clipboards} *)

(** Storing data on clipboards
   @gtkdoc gtk gtk-Clipboards *)
class clipboard_skel : Gtk.clipboard Lazy.t ->
  object
    method as_clipboard : Gtk.clipboard
    method clear : unit -> unit
    method get_contents : target:Gdk.atom -> GObj.selection_data
    method set_image : GdkPixbuf.pixbuf -> unit
    method set_text : string -> unit
    method image : GdkPixbuf.pixbuf option
    method text : string option
    method targets : Gdk.atom list
  end

class clipboard : selection:Gdk.atom ->
  object
    inherit clipboard_skel
    method set_contents :
      targets:string list ->
      get:(GObj.selection_context -> info:int -> time:int32 -> unit) ->
      clear:(unit -> unit) -> unit
  end

(** @gtkdoc gtk gtk-Clipboards *)
val clipboard : Gdk.atom -> clipboard
val as_clipboard : clipboard -> Gtk.clipboard
