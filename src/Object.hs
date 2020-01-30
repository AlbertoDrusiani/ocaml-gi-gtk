module Object
  ( genObject
  , genGObjectCasts
  , genInterface
  )
where

import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Control.Monad                  ( forM_
                                                , when
                                                , unless
                                                , filterM
                                                , forM
                                                )

import           Data.GI.GIR.BasicTypes         ( Type(TInterface) )
import           Data.Maybe                     ( fromMaybe )
import           Data.List                      ( nub )

import           API
import           Code
import           GObject
import           Inheritance                    ( instanceTree )
import           Method                         ( genMethod )
import           Properties                     ( genObjectProperties
                                                , genInterfaceProperties
                                                )
import           Signal                         ( genSignal
                                                , genGSignal
                                                )
import           SymbolNaming
import           Files                          ( excludeFiles
                                                , genFiles
                                                )

isSetterOrGetter :: Object -> Method -> Bool
isSetterOrGetter o m =
  let props = objProperties o
  in  let propNames = map (hyphensToUnderscores . propName) props
      in  let mName = name $ methodName m
          in  ("get" `T.isPrefixOf` mName || "set" `T.isPrefixOf` mName)
                && any (`T.isSuffixOf` mName) propNames

genGObjectCasts :: Name -> Text -> CodeGen ()
genGObjectCasts n ctype = do
  let upperType = T.toUpper (camelCaseToSnakeCase ctype)
  hline
    ("#define " <> objectVal n <> "(val) check_cast(" <> upperType <> ", val)")
  -- hline $ "#define " <> nspace <> n <> "_val(" <> "val) ((" <> x <> "*) val)"
  hline $ "#define " <> valObject n <> " Val_GAnyObject"
  cline ("Make_Val_option(" <> ctype <> "," <> valObject n <> ")")
  hline ("value " <> valOptObject n <> " (" <> ctype <> "*);")
  addCDep (namespace n <> name n)

genSignalClass :: Name -> Object -> CodeGen ()
genSignalClass n o = do
  let objectName = name n
      ocamlName  = camelCaseToSnakeCase objectName

  gline $ "class " <> ocamlName <> "_signals obj = object (self)"

  parents <- instanceTree n

  case name $ head parents of
    "Container" -> gline "  inherit GContainer.container_signals_impl obj"
    "Widget"    -> gline "  inherit GObj.widget_signals_impl obj"
    "Object"    -> gline "  inherit [_] GObj.gobject_signals obj"
    parent      -> do
      let ocamlParentName = camelCaseToSnakeCase parent
      gline
        ("  inherit " <> parent <> "G." <> ocamlParentName <> "_signals obj")

  forM_ (objSignals o) $ \s -> genGSignal s n
  gline "end"
  gblank

genObjectTypeInit :: Object -> Text -> CodeGen ()
genObjectTypeInit o cTypeName = when (objTypeInit o /= "") $ cline $ T.unlines
  [ "CAMLprim value ml_" <> cTypeName <> "_init(value unit) {"
  , "    GType t = " <> objTypeInit o <> "();"
  , "    return Val_GType(t);"
  , "}"
  ]

-- | Wrap a given Object. We enforce that every Object that we wrap is a
-- GObject. This is the case for everything except the ParamSpec* set
-- of objects, we deal with these separately.
genObject :: Name -> Object -> CodeGen ()
genObject n o = do
  isGO <- isGObject (TInterface n)
  if not isGO || n `elem` excludeFiles
    then commentLine
      (upperName n <> " does not descend from GObject, it will be ignored.")
    else do
      let objectName = name n
          ocamlName  = escapeOCamlReserved $ camelCaseToSnakeCase objectName

      parents <- instanceTree n

      genModuleType parents ocamlName

      when (objectName == "Widget") $ do
        gline "class type widget_o = object"
        gline "  method as_widget : Widget.t Gobject.obj"
        gline "end"

      forM_ (objCType o) (genGObjectCasts n)

      if namespace n /= "Gtk" || n `notElem` genFiles
        then commentLine "Ignored: This file has been ignored by the settings in Files.hs"
        else genObject' n o ocamlName
 where
  genModuleType parents ocamlName = case parents of
    [] -> line $ "type t = [`" <> ocamlName <> "]"
    _  -> do
      let parent = head parents
          parentType =
            case (name parent == "Object", namespace parent == "Gtk") of
              (True, _   ) -> "`giu"
              (_   , True) -> "" <> name parent <> ".t"
              _            -> "`" <> camelCaseToSnakeCase (name parent)
      line $ "type t = [" <> parentType <> " | `" <> ocamlName <> "]"

genObject' :: Name -> Object -> Text -> CodeGen ()
genObject' n o ocamlName = do
  parents <- instanceTree n
  let name'               = upperName n
      nspace              = namespace n
      objectName          = name n
      namespacedOcamlName = camelCaseToSnakeCase $ nspace <> objectName
      parent              = head parents
      ocamlParentName     = camelCaseToSnakeCase $ name parent

  genObjectTypeInit o namespacedOcamlName

  gline "open GtkSignal"
  gline "open Gobject"
  gline "open Data"
  gblank
  gline $ "open " <> objectName
  gblank

  gline $ "class type " <> ocamlName <> "_o = object"
  gline $ "  method as_" <> ocamlName <> " : t obj"
  gline "end"
  gblank

  let namespacedParentName = case name parent of
        "Container" -> "['a] GContainer.container_impl"
        "Widget"    -> "['a] GObj.widget_impl"
        "Object"    -> "GObj.gtkobj"
        _           -> name parent <> "G." <> ocamlParentName <> "_skel"
  gline $ "class " <> ocamlName <> "_skel obj = object (self)"
  gline $ "  inherit " <> namespacedParentName <> " obj"
  gline $ "  method as_" <> ocamlName <> " = (obj :> t obj)"

  line "open Gobject"
  line "open Data"
  blank
  line "open Gtk"
  blank

  group $ do
    line
      $  "external ml_"
      <> namespacedOcamlName
      <> "_init : unit -> unit = \"ml_"
      <> namespacedOcamlName
      <> "_init\""
    line $ "let () = ml_" <> namespacedOcamlName <> "_init ()"

  group $ do
    genObjectProperties n o
    gblank

  unless (null $ objSignals o) $ group $ do
    line "module S = struct"
    indent $ do
      line $ "open " <> nspace <> "Signal"
      forM_ (objSignals o) $ \s -> genSignal s n

    line "end"

  group
    $  line
    $  "let cast w : "
    <> "t obj = try_cast w \""
    <> nspace
    <> objectName
    <> "\""

  group
    $  line
    $  "let create pl : "
    <> "t obj = GtkObject.make \""
    <> nspace
    <> objectName
    <> "\" pl"

  -- Methods
  gline "  (* Methods *)"
  let methods  = objMethods o
  let methods' = filter (not . isSetterOrGetter o) methods

  forM_ methods' $ \f -> do
    let mn = methodName f
    handleCGExc
      (\e -> line
        (  "(* Could not generate method "
        <> name'
        <> "::"
        <> name mn
        <> " *)\n"
        <> "(* Error was : "
        <> describeCGError e
        <> " *)"
        )
      )
      (genMethod n f)
  gline "end"
  gblank

  genSignalClass n o

  gline $ "class " <> ocamlName <> " obj = object (self)"
  gline $ "  inherit " <> ocamlName <> "_skel obj"
  unless (null $ objSignals o)
    $  group
    $  gline
    $  "  method connect = new "
    <> ocamlName
    <> "_signals obj"
  gline "end"

  if "Widget" `elem` map name parents
    then do
      gline "let pack_return create p ?packing ?show () ="
      gline "  GObj.pack_return (create p) ~packing ~show"

      gline $ "let " <> ocamlName <> " = "
      gline $ "  " <> objectName <> ".make_params [] ~cont:("
      gline
        $  "    pack_return (fun p -> new "
        <> ocamlName
        <> " ("
        <> objectName
        <> ".create p)))"
    else do
      gline $ "let " <> ocamlName <> " = "
      gline
        $  "  "
        <> objectName
        <> ".make_params [] ~cont:(fun p -> new "
        <> ocamlName
        <> " ("
        <> objectName
        <> ".create p))"

genInterface :: Name -> Interface -> CodeGen ()
genInterface n iface = do
  let name'     = upperName n
      ocamlName = escapeOCamlReserved $ camelCaseToSnakeCase (name n)

  -- addSectionDocumentation ToplevelSection (ifDocumentation iface)
  forM_ (ifCType iface) (genGObjectCasts n)

  line $ "type t = [`" <> ocamlName <> "]"

  -- when (namespace n == "Gtk") $ do
  --   line "open Gobject"
  --   line "open Data"
  --   line "open Gtk"

  --   line "module S = struct"
  --   indent $ line "open GtkSignal"
  --   indent $ forM_ (ifSignals iface) $ \s -> handleCGExc
  --     ( commentLine
  --     . (T.concat
  --         [ "Could not generate signal "
  --         , name'
  --         , "::"
  --         , sigName s
  --         , " *)\n"
  --         , "(* Error was : "
  --         ] <>
  --       )
  --     . describeCGError
  --     )
  --     (genSignal s n)
  --   line "end"

  --   isGO <- apiIsGObject n (APIInterface iface)

  --   when isGO $ genInterfaceProperties n iface

  -- forM_ (ifMethods iface) $ \f -> do
  --   let mn = methodName f
  --   isFunction <- symbolFromFunction (methodSymbol f)
  --   unless isFunction $ handleCGExc
  --     (\e -> line
  --       (  "(* Could not generate method "
  --       <> name'
  --       <> "::"
  --       <> name mn
  --       <> " *)\n"
  --       <> "(* Error was : "
  --       <> describeCGError e
  --       <> " *)"
  --       )
  --     )
  --     (genMethod n f)
