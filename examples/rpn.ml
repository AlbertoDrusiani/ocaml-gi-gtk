(**************************************************************************)
(*    Lablgtk - Examples                                                  *)
(*                                                                        *)
(*    This code is in the public domain.                                  *)
(*    You may freely copy parts of it in your application.                *)
(*                                                                        *)
(**************************************************************************)

(* $Id$ *)

(* reverse polish calculator *)

module S = Stack

open GIGtk

open StdLabels

let _ = GMain.init ()

let wow _ = prerr_endline "Wow!"; ()
let main () =
  let stack = S.create () in	

  (* toplevel window *)
  let window =
    WindowG.window ~border_width: 10 ~title:"Reverse Polish Calculator" () in
  window#connect#destroy ~callback:GMain.quit;


  (* vbox *)
  let vbx = VBoxG.v_box ~packing:window#add () in

  (* entry *)
  let entry =
    EntryG.entry ~text:"0" ~editable:false ~max_length: 20 ~packing: vbx#add () in

  (* BackSpace, Clear, All Clear, Quit *) 
  let table0 = TableG.table ~n_rows:1 ~n_columns:4 ~packing:vbx#add () in
  let bs_clicked _ = begin
    let txt = entry#get_text in
    let len = String.length txt in 
    if len <= 1 then
      entry#set_text "0"
    else entry#set_text (String.sub txt ~pos:0 ~len:(len-1))
  end in
  let c_clicked _ = entry#set_text("0") in
  let ac_clicked _ = S.clear stack; entry#set_text("0") in
  let labels0 = [("BS", bs_clicked) ; ("C", c_clicked);
		 ("AC", ac_clicked); ("Quit", window#destroy)] in
  let rec loop0 labels n =
    match labels 
    with  [] -> ()
        | (lbl, cb) :: t  ->
    let button =
      ButtonG.button ~label:lbl
        ~packing:(Lablgtk3Compat.attach table0 ~left:n ~top:1 ~expand:`BOTH) () in
    button#connect#clicked ~callback:cb;
    loop0 t (n+1) in
  loop0 labels0 1;

  (* Numerals *)
  let table1 = TableG.table ~n_rows:4 ~n_columns:5 ~packing:vbx#add () in
  let labels1 = ["7"; "8"; "9"; "4"; "5"; "6"; "1"; "2"; "3"; "0"] in
  let numClicked n _ =
     let txt = entry#get_text in
     if (txt = "0") then
       entry#set_text n
     else begin
       entry#set_text (entry#get_text ^ n) (* entry#append_text n *)
     end in
  let rec loop1 labels n =
    match labels with [] -> ()
    | lbl :: lbls ->
        let button = ButtonG.button ~label:(" "^lbl^" ")
	    ~packing:(Lablgtk3Compat.attach table1 ~left:(n mod 3) ~top:(n/3) ~expand:`BOTH)
            () in
        button#connect#clicked ~callback:(numClicked lbl);
        loop1 lbls (n+1) in
  loop1 labels1 0; 

  (* Period *)
  let periodClicked _ = 
     let txt = entry#get_text in
     if not (String.contains txt '.') then
       entry#set_text (entry#get_text ^ ".") (* entry#append_text "." *)
  in
  (ButtonG.button ~label:" . "
     ~packing:(Lablgtk3Compat.attach table1 ~left:1 ~top:3 ~expand:`BOTH) ())
    #connect#clicked ~callback:periodClicked;

  (* Enter (Push) *)
  let enterClicked _ =
     let txt = entry#get_text in
     let n = float_of_string txt in begin
       S.push n stack;
       entry#set_text "0"
     end in
  (ButtonG.button ~label:"Ent"
     ~packing:(Lablgtk3Compat.attach table1 ~left:2 ~top:3 ~expand:`BOTH) ())
    #connect#clicked ~callback:enterClicked;

  (* Operators *)
  let op2Clicked op _ =
    let n1 = float_of_string (entry#get_text) in
    let n2 = S.pop stack in
    entry#set_text (string_of_float (op n2 n1)) 
  in
  let op1Clicked op _ =
    let n1 = float_of_string (entry#get_text) in
    entry#set_text (string_of_float (op n1)) 
  in
  let modClicked _ =
    let n1 = int_of_string (entry#get_text) in
    let n2 = truncate (S.pop stack) in
    entry#set_text (string_of_int (n2 mod n1))
  in
  let labels2 = [(" / ", op2Clicked (/.)); (" * ", op2Clicked ( *. ));
		 (" - ", op2Clicked (-.)); (" + ", op2Clicked (+.));
		 ("mod", modClicked); (" ^ ", op2Clicked ( ** ));
		 ("+/-", op1Clicked (~-.));
                 ("1/x", op1Clicked (fun x -> 1.0/.x))] in
  let rec loop2 labels n =
    match labels
    with [] -> ()
    | (lbl, cb) :: t ->
	let button = ButtonG.button ~label:lbl
            ~packing:(Lablgtk3Compat.attach table1 ~left:(3 + n/4) ~top: (n mod 4)
                        ~expand:`BOTH)
            () in
	button#connect#clicked ~callback:cb;
	loop2 t (n+1)
  in
  loop2 labels2 0;

  (* show all and enter event loop *)
  window#misc#show ();
  GMain.main ()

let _ = Printexc.print main()