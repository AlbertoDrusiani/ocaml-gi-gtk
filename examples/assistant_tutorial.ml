(**************************************************************************)
(*    Lablgtk - Examples                                                  *)
(*                                                                        *)
(*    This code is in the public domain.                                  *)
(*    You may freely copy parts of it in your application.                *)
(*                                                                        *)
(**************************************************************************)

(* $Id: $ *)

open GIGtk

(* The tutorial is translated to OCaml from Chapter 5 of Foundations of 
   GTK+ Development (published April 2007). You can find more information
   about the book at http://www.gtkbook.com. *)
(* See also 
   {http://www.linuxquestions.org/linux/articles/Technical/New_GTK_Widgets_GtkAssistant} *)

(* If there is text in the GtkEntry, set the page as complete. Otherwise,
  stop the user from progressing the next page. *)
let entry_changed (assistant : #AssistantG.assistant) entry () = 
  let text = entry#get_text in
  let num = assistant#get_current_page in
  let page = assistant#get_nth_page num in
  assistant#set_page_complete (Option.get page) (String.length (text) > 0)

(* If the check button is toggled, set the page as complete. Otherwise,
   stop the user from progressing the next page. *)
let button_toggled toggle (assistant : #AssistantG.assistant) () = 
  let active = toggle#get_active in
  assistant#set_page_complete toggle active


(* Fill up the progress bar, 10% every second when the button is clicked. Then,
  set the page as complete when the progress bar is filled. *)
let button_clicked button (assistant : #AssistantG.assistant) progress () = 
  let percent = ref 0.0 in
  button#set_sensitive false;
  while (!percent <= 100.0) do
    let message = Printf.sprintf "%.0f%% Complete" !percent in
    progress#set_fraction (!percent /. 100.0);
    progress#set_text message;
    
    while Glib.Main.pending () do
      Glib.Main.iteration true
    done;
    
    Glib.usleep 500000;
    percent := !percent +. 5.0;
  done;
  let page = Option.get (assistant#get_nth_page 3) in
  assistant#set_page_complete page true



(* If the dialog is cancelled, delete it from memory and then clean up after
   the Assistant structure. *)
let assistant_cancel assistant () = 
  assistant#destroy
    
(* This function is where you would apply the changes and destroy 
   the assistant. *)
let assistant_close assistant () = 
  prerr_endline "You would apply your changes now!";
  assistant#destroy



let main () =
  GMain.init ();
  let assistant = AssistantG.assistant ~width_request:450 ~height_request:300 () in
  assistant#set_title "GtkAssistant Example";
  assistant#connect#destroy (fun () -> exit 0);
  let page_0 = LabelG.label ~label:"This is an example of a GtkAssistant. By
clicking the forward button, you can continue
to the next section!"
    ()
  in
  let page_1 = HBoxG.h_box ~homogeneous:false ~spacing:5 () in
  let page_2 = CheckButtonG.check_button ~label:"Click Me To Continue!" () in
  let page_3 = 
    AlignmentG.alignment ~xalign:0.5 ~yalign:0.5 ~xscale:0.0 ~yscale:0.0 ()
  in
  let page_4 =  LabelG.label ~label:"Text has been entered in the label and the
combo box is clicked. If you are done, then
it is time to leave!" () 
  in
  
  (* Create the necessary widgets for the second page. *)
  let _label = LabelG.label  
    ~label:"Your Name: " 
    ~packing:(Lablgtk3Compat.pack page_1 ~expand:false ~fill:false ~padding:5) 
    () 
  in
  let entry = EntryG.entry 
    ~packing:(Lablgtk3Compat.pack page_1 ~expand:false ~fill:false ~padding:5) 
    ()
  in

(* Create the necessary widgets for the fourth page. 
   Then Attach the progress bar to the GtkAlignment widget for later access.*)
  let button = ButtonG.button ~label:"Click me!" () in
  let progress = ProgressBarG.progress_bar () in
  let hbox = HBoxG.h_box ~homogeneous:false ~spacing:5 () in
  Lablgtk3Compat.pack hbox ~expand:true ~fill:false ~padding:5 progress;
  Lablgtk3Compat.pack hbox ~expand:false ~fill:false ~padding:5 button;
  page_3#add hbox;

  (* Add five pages to the GtkAssistant dialog. *)
  Lablgtk3Compat.append_page assistant
    ~title:"Introduction" 
    ~page_type:`INTRO 
    ~complete:true
    page_0;
  Lablgtk3Compat.append_page assistant
    ~page_type:`CONTENT 
    page_1;
  Lablgtk3Compat.append_page assistant
    ~title:"Click the Check Button"
    ~page_type:`CONTENT 
    page_2;
  Lablgtk3Compat.append_page assistant
     ~title:"Click the Button"
    ~page_type:`PROGRESS 
    page_3;
  Lablgtk3Compat.append_page assistant
     ~title:"Confirmation"
    ~page_type:`CONFIRM
    ~complete:true
    page_4;

 (* Update whether pages 2 through 4 are complete based upon whether there is
    text in the GtkEntry, the check button is active, or the progress bar
    is completely filled. *)
  entry#connect#changed ~callback:(entry_changed assistant entry);
  page_2#connect#toggled ~callback:(button_toggled page_2 assistant);
  button#connect#clicked ~callback:(button_clicked button assistant progress);
  assistant#connect#cancel ~callback:(assistant_cancel assistant);
  assistant#connect#close ~callback:(assistant_close assistant);

  assistant#show;
  GMain.main ()


let () = 
  main ()
    
