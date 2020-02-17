(**************************************************************************)
(*    Lablgtk - Examples                                                  *)
(*                                                                        *)
(*    This code is in the public domain.                                  *)
(*    You may freely copy parts of it in your application.                *)
(*                                                                        *)
(**************************************************************************)

open GIGtk

let _ = GMain.init ()
let w = WindowG.window ~show:true ()
let e = EntryG.entry ~packing:w#add ()

let () =
(*XXX
  e#connect#after#insert_text
    (fun _ ~pos ->
      if e#text_length > 5 then e#set_secondary_icon_stock `DIALOG_WARNING
      else e#set_secondary_icon_name "");
*)
  w#event#connect#delete (fun _ -> GMain.quit (); true);
  GMain.main ()
