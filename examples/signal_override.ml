(**************************************************************************)
(*    Lablgtk - Examples                                                  *)
(*                                                                        *)
(*    This code is in the public domain.                                  *)
(*    You may freely copy parts of it in your application.                *)
(*                                                                        *)
(**************************************************************************)

open GIGtk

module C = Gobject.Closure

let add_closure argv =
  Printf.eprintf "invoking overridden ::add closure, %d args, " argv.C.nargs ;
  let typ = C.get_type argv 1 in
  Printf.eprintf "widget %s\n" (Gobject.Type.name typ) ;
  flush stderr ;
  GtkSignal.chain_from_overridden argv

let derived_frame_name = "GtkFrameCaml"

let derived_frame_gtype = 
  lazy begin
    let parent = Gobject.Type.from_name "GtkFrame" in
    let t = Gobject.Type.register_static ~parent ~name:derived_frame_name in
    GtkSignal.override_class_closure Container.S.add t
      (C.create add_closure) ;
    t
  end

let pack_container ~create =
  Container.make_params ~cont:
    (fun p ?packing ?show () -> GObj.pack_return (create p) ~packing ~show)

let create_derived_frame =
  Frame.make_params [] 
    ~cont:(fun pl -> 
      pack_container pl 
	~create:(fun pl -> 
	  ignore (Lazy.force derived_frame_gtype) ;
	  new FrameG.frame (GtkObject.make derived_frame_name pl)))

let main =
  GMain.init ();
  let w = WindowG.window ~title:"Overriding signals demo" () in
  w#connect#destroy GMain.quit ;

  let f = create_derived_frame ~label:"Talking frame" ~packing:w#add () in

  let l = LabelG.label ~use_markup:true ~label:"This is the <b>GtkFrame</b>'s content" ~packing:f#add () in

  w#misc#show () ;
  GMain.main ()
